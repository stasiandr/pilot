package pilot;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import org.slf4j.LoggerFactory;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;

import jadx.api.ICodeInfo;
import jadx.api.JadxArgs;
import jadx.api.JadxDecompiler;
import jadx.api.JavaClass;
import jadx.api.JavaNode;
import jadx.api.ResourceFile;
import jadx.api.ResourceType;
import jadx.api.metadata.ICodeAnnotation;
import jadx.api.metadata.ICodeNodeRef;
import jadx.api.metadata.annotations.NodeDeclareRef;
import jadx.api.metadata.annotations.VarNode;
import jadx.api.metadata.annotations.VarRef;
import jadx.core.dex.info.AccessInfo;
import jadx.core.dex.nodes.ClassNode;
import jadx.core.dex.nodes.FieldNode;
import jadx.core.dex.nodes.MethodNode;
import jadx.core.xmlgen.ResContainer;

/**
 * Line-delimited JSON bridge between Pilot and jadx: APK, JAR and DEX open as read-only projects.
 * Requests on stdin: {"id":1,"method":"open","params":{...}}.
 * Replies on stdout: {"id":1,"result":...} or {"id":1,"error":"..."};
 * unsolicited messages: {"event":"...","data":...}.
 * Everything jadx logs goes to stderr.
 */
public final class JadxEngine {
	// Span kinds sent with the code. Declarations are 1..4, references 11..15.
	static final int DECL_CLASS = 1, DECL_METHOD = 2, DECL_FIELD = 3, DECL_VAR = 4;
	static final int REF_CLASS = 11, REF_METHOD = 12, REF_FIELD = 13, REF_VAR = 14, REF_PKG = 15;

	private static final int MAX_NAME_HITS = 3000;
	private static final int MAX_CODE_HITS = 5000;

	private final Gson gson = new Gson();
	private final OutputStream out;
	private final ExecutorService pool = Executors.newCachedThreadPool(r -> {
		Thread t = new Thread(r, "jadx-request");
		t.setDaemon(true);
		return t;
	});
	private final Map<String, AtomicBoolean> cancels = new ConcurrentHashMap<>();

	private volatile JadxDecompiler jadx;
	private volatile Map<String, JavaClass> classes = Collections.emptyMap();
	private volatile Map<String, ResourceFile> resources = Collections.emptyMap();
	private final Map<String, List<ResContainer>> tableFiles = new ConcurrentHashMap<>();

	private JadxEngine(OutputStream out) {
		this.out = out;
	}

	public static void main(String[] args) throws Exception {
		OutputStream protocol = new FileOutputStream(FileDescriptor.out);
		System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
		((Logger) LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME)).setLevel(Level.WARN);
		new JadxEngine(protocol).run();
	}

	private void run() throws Exception {
		event("ready", obj("version", JadxDecompiler.getVersion()));
		BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
		String line;
		while ((line = in.readLine()) != null) {
			if (line.isBlank()) {
				continue;
			}
			JsonObject req = gson.fromJson(line, JsonObject.class);
			long id = req.get("id").getAsLong();
			String method = req.get("method").getAsString();
			JsonObject params = req.has("params") ? req.getAsJsonObject("params") : new JsonObject();
			if (method.equals("cancel")) {
				AtomicBoolean flag = cancels.get(params.get("token").getAsString());
				if (flag != null) {
					flag.set(true);
				}
				reply(id, null);
				continue;
			}
			pool.execute(() -> {
				try {
					reply(id, handle(method, params));
				} catch (Throwable e) {
					e.printStackTrace();
					String msg = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
					send(obj("id", id, "error", msg));
				}
			});
		}
		System.exit(0);
	}

	private Object handle(String method, JsonObject p) throws Exception {
		switch (method) {
			case "open": return open(p);
			case "code": return code(cls(p));
			case "smali": return obj("code", cls(p).getSmali());
			case "resolve": return resolve(cls(p), p.get("pos").getAsInt());
			case "usages": return usages(cls(p), p.get("pos").getAsInt());
			case "locate": return locate(p);
			case "resource": return resource(p);
			case "search": return search(p);
			case "export": return export(p);
			default: throw new IllegalArgumentException("Unknown method " + method);
		}
	}

	// ---- open ----

	private Object open(JsonObject p) {
		List<File> files = new ArrayList<>();
		for (JsonElement e : p.getAsJsonArray("paths")) {
			files.add(new File(e.getAsString()));
		}
		JadxArgs args = new JadxArgs();
		args.setInputFiles(files);
		args.setShowInconsistentCode(true);
		args.setThreadsCount(Math.max(1, Runtime.getRuntime().availableProcessors() - 1));
		if (p.has("deobfuscate") && p.get("deobfuscate").getAsBoolean()) {
			args.setDeobfuscationOn(true);
		}
		JadxDecompiler d = new JadxDecompiler(args);
		d.load();

		Map<String, JavaClass> clsMap = new ConcurrentHashMap<>();
		JsonArray clsArr = new JsonArray();
		for (JavaClass c : d.getClasses()) {
			clsMap.put(c.getRawName(), c);
			AccessInfo a = c.getAccessInfo();
			String kind = a.isAnnotation() ? "a" : a.isInterface() ? "i" : a.isEnum() ? "e" : "c";
			JsonArray row = new JsonArray();
			row.add(c.getRawName());
			row.add(c.getFullName());
			row.add(kind);
			clsArr.add(row);
		}
		Map<String, ResourceFile> resMap = new ConcurrentHashMap<>();
		JsonArray resArr = new JsonArray();
		for (ResourceFile r : d.getResources()) {
			if (r.getType() == ResourceType.CODE) {
				continue;
			}
			resMap.put(r.getDeobfName(), r);
			JsonArray row = new JsonArray();
			row.add(r.getDeobfName());
			row.add(r.getType().name());
			resArr.add(row);
		}
		// resources.arsc decodes into res/values*/... files that don't exist in the archive itself.
		Map<String, List<ResContainer>> tables = new ConcurrentHashMap<>();
		JsonObject tableArr = new JsonObject();
		for (ResourceFile r : d.getResources()) {
			if (r.getType() != ResourceType.ARSC) {
				continue;
			}
			try {
				ResContainer rc = r.loadContent();
				if (rc.getDataType() != ResContainer.DataType.RES_TABLE) {
					continue;
				}
				List<ResContainer> subs = new ArrayList<>(rc.getSubFiles());
				tables.put(r.getDeobfName(), subs);
				JsonArray names = new JsonArray();
				for (ResContainer sub : subs) {
					names.add(sub.getName());
				}
				tableArr.add(r.getDeobfName(), names);
			} catch (Throwable e) {
				e.printStackTrace();
			}
		}

		JadxDecompiler old = jadx;
		jadx = d;
		classes = clsMap;
		resources = resMap;
		tableFiles.clear();
		tableFiles.putAll(tables);
		if (old != null) {
			old.close();
		}
		return obj("classes", clsArr, "resources", resArr, "tables", tableArr, "version", JadxDecompiler.getVersion());
	}

	/**
	 * Decompiled code without JavaClass.getCodeInfo(): its member-list loading recurses through
	 * inlined classes and can spin for minutes on Kotlin-heavy apps.
	 */
	private static ICodeInfo codeOf(JavaClass c) {
		return c.getClassNode().getCode();
	}

	private JavaClass cls(JsonObject p) {
		String name = p.get("cls").getAsString();
		JavaClass c = classes.get(name);
		if (c == null) {
			throw new IllegalArgumentException("No class " + name);
		}
		return c;
	}

	// ---- code ----

	private Object code(JavaClass c) {
		ICodeInfo info = codeOf(c);
		String code = info.getCodeStr();
		JsonArray spans = new JsonArray();
		if (info.hasMetadata()) {
			java.util.TreeMap<Integer, ICodeAnnotation> sorted = new java.util.TreeMap<>(info.getCodeMetadata().getAsMap());
			for (Map.Entry<Integer, ICodeAnnotation> e : sorted.entrySet()) {
				int kind = spanKind(e.getValue());
				if (kind == 0) {
					continue;
				}
				int pos = e.getKey();
				int len = identLength(code, pos);
				if (len == 0) {
					continue;
				}
				if (kind == REF_CLASS) {
					// Fully qualified references (imports, clashing names) cover the whole dotted name,
					// stopping before the next annotated token.
					Integer next = sorted.higherKey(pos);
					int limit = next == null ? code.length() : next;
					int end = pos + len;
					while (end + 1 < limit && code.charAt(end) == '.' && Character.isJavaIdentifierStart(code.charAt(end + 1))) {
						end = end + 1 + identLength(code, end + 1);
					}
					len = Math.min(end, limit) - pos;
				}
				spans.add(pos);
				spans.add(len);
				spans.add(kind);
			}
		}
		return obj("code", code, "spans", spans);
	}

	private static int spanKind(ICodeAnnotation ann) {
		switch (ann.getAnnType()) {
			case CLASS: return REF_CLASS;
			case METHOD: return REF_METHOD;
			case FIELD: return REF_FIELD;
			case PKG: return REF_PKG;
			case VAR: return DECL_VAR;
			case VAR_REF: return REF_VAR;
			case DECLARATION:
				switch (((NodeDeclareRef) ann).getNode().getAnnType()) {
					case CLASS: return DECL_CLASS;
					case METHOD: return DECL_METHOD;
					case FIELD: return DECL_FIELD;
					case VAR: return DECL_VAR;
					default: return 0;
				}
			default: return 0;
		}
	}

	private static int identLength(String code, int pos) {
		int i = pos;
		while (i < code.length() && Character.isJavaIdentifierPart(code.charAt(i))) {
			i++;
		}
		return i - pos;
	}

	// ---- navigation ----

	/** Declaration of the node referenced at pos, as {cls, pos}; null for nodes outside the input. */
	private Object resolve(JavaClass c, int pos) {
		ICodeInfo info = codeOf(c);
		ICodeAnnotation ann = info.getCodeMetadata().getAt(pos);
		if (ann == null) {
			return null;
		}
		if (ann instanceof VarRef) {
			return location(c, info.getCodeStr(), ((VarRef) ann).getRefPos());
		}
		if (ann instanceof VarNode) {
			return location(c, info.getCodeStr(), pos);
		}
		JavaNode node = jadx.getJavaNodeByCodeAnnotation(info, ann);
		return node == null ? null : nodeLocation(node);
	}

	private Object nodeLocation(JavaNode node) {
		JavaClass top = node.getTopParentClass();
		if (top == null || !classes.containsKey(top.getRawName())) {
			return null;
		}
		return location(top, codeOf(top).getCodeStr(), node.getDefPos());
	}

	/** Where a search hit is declared: {cls, ref?: id handed out by the name search}. */
	private Object locate(JsonObject p) {
		JavaClass c = cls(p);
		if (!p.has("ref")) {
			return location(c, codeOf(c).getCodeStr(), c.getDefPos());
		}
		ICodeNodeRef ref = refs.get(p.get("ref").getAsInt());
		JavaNode node = ref == null ? null : jadx.getJavaNodeByRef(ref);
		return node == null ? null : nodeLocation(node);
	}

	private Object usages(JavaClass c, int pos) {
		ICodeInfo info = codeOf(c);
		String code = info.getCodeStr();
		ICodeAnnotation ann = info.getCodeMetadata().getAt(pos);
		JsonArray hits = new JsonArray();
		if (ann == null) {
			return hits;
		}
		if (ann instanceof VarRef || ann instanceof VarNode) {
			int declPos = ann instanceof VarRef ? ((VarRef) ann).getRefPos() : pos;
			for (Map.Entry<Integer, ICodeAnnotation> e : new java.util.TreeMap<>(info.getCodeMetadata().getAsMap()).entrySet()) {
				ICodeAnnotation a = e.getValue();
				if (a instanceof VarRef && ((VarRef) a).getRefPos() == declPos) {
					hits.add(hit(c, code, e.getKey()));
				}
			}
			return hits;
		}
		JavaNode node = jadx.getJavaNodeByCodeAnnotation(info, ann);
		if (node == null) {
			return hits;
		}
		java.util.Set<String> seen = new java.util.HashSet<>();
		for (JavaNode user : node.getUseIn()) {
			JavaClass top = user.getTopParentClass();
			if (top == null || !seen.add(top.getRawName())) {
				continue;
			}
			ICodeInfo topInfo = codeOf(top);
			String topCode = topInfo.getCodeStr();
			for (int usePos : top.getUsePlacesFor(topInfo, node)) {
				hits.add(hit(top, topCode, usePos));
			}
		}
		return hits;
	}

	/** {cls, pos, line, col}: line from 0 and col in UTF-16 units, as Pilot addresses positions. */
	private JsonObject location(JavaClass c, String code, int pos) {
		int lineStart = pos == 0 ? 0 : code.lastIndexOf('\n', pos - 1) + 1;
		int line = 0;
		for (int i = 0; i < lineStart; i++) {
			if (code.charAt(i) == '\n') {
				line++;
			}
		}
		return obj("cls", c.getRawName(), "pos", pos, "line", line, "col", pos - lineStart);
	}

	private JsonObject hit(JavaClass c, String code, int pos) {
		int start = code.lastIndexOf('\n', pos - 1) + 1;
		int end = code.indexOf('\n', pos);
		if (end < 0) {
			end = code.length();
		}
		int line = 1;
		for (int i = 0; i < start; i++) {
			if (code.charAt(i) == '\n') {
				line++;
			}
		}
		return obj("cls", c.getRawName(), "name", c.getFullName(), "pos", pos, "line", line - 1,
				"col", pos - start, "text", code.substring(start, end).strip());
	}

	// ---- resources ----

	private Object resource(JsonObject p) {
		String name = p.get("name").getAsString();
		ResContainer rc;
		if (p.has("sub")) {
			List<ResContainer> subs = tableFiles.get(name);
			if (subs == null) {
				resource(obj("name", name));
				subs = tableFiles.get(name);
			}
			int idx = p.get("sub").getAsInt();
			rc = subs.get(idx);
		} else {
			ResourceFile rf = resources.get(name);
			if (rf == null) {
				throw new IllegalArgumentException("No resource " + name);
			}
			rc = rf.loadContent();
		}
		switch (rc.getDataType()) {
			case TEXT:
				return obj("kind", "text", "text", rc.getText().getCodeStr());
			case DECODED_DATA:
				return obj("kind", "data", "data", Base64.getEncoder().encodeToString(rc.getDecodedData()));
			case RES_TABLE: {
				List<ResContainer> subs = new ArrayList<>(rc.getSubFiles());
				tableFiles.put(name, subs);
				JsonArray names = new JsonArray();
				for (ResContainer s : subs) {
					names.add(s.getName());
				}
				return obj("kind", "table", "text", rc.getText().getCodeStr(), "files", names);
			}
			case RES_LINK:
				return obj("kind", "data", "data", Base64.getEncoder().encodeToString(rc.getResLink().getZipEntry().getBytes()));
			default:
				throw new IllegalStateException("Unsupported resource " + rc.getDataType());
		}
	}

	// ---- search ----

	private final Map<Integer, ICodeNodeRef> refs = new ConcurrentHashMap<>();
	private final AtomicInteger refSeq = new AtomicInteger();

	private Object search(JsonObject p) throws Exception {
		String token = p.get("token").getAsString();
		String query = p.get("query").getAsString();
		boolean inCode = p.has("code") && p.get("code").getAsBoolean();
		boolean matchCase = p.has("matchCase") && p.get("matchCase").getAsBoolean();
		AtomicBoolean cancelled = new AtomicBoolean();
		cancels.put(token, cancelled);
		try {
			return inCode
					? searchCode(token, query, matchCase, cancelled)
					: searchNames(token, query, matchCase, cancelled);
		} finally {
			cancels.remove(token);
		}
	}

	private Object searchNames(String token, String query, boolean matchCase, AtomicBoolean cancelled) {
		String q = matchCase ? query : query.toLowerCase(Locale.ROOT);
		refs.clear();
		JsonArray items = new JsonArray();
		List<JavaClass> all = new ArrayList<>(classes.values());
		all.sort((a, b) -> a.getFullName().compareTo(b.getFullName()));
		outer:
		for (JavaClass top : all) {
			if (cancelled.get()) {
				break;
			}
			for (ClassNode cn : withInners(top.getClassNode())) {
				String clsName = cn.getAlias();
				if (matches(clsName, q, matchCase)) {
					items.add(nameHit(top, cn, "c", clsName, cn.getFullName()));
				}
				for (MethodNode m : cn.getMethods()) {
					if (m.getMethodInfo().isClassInit()) {
						continue;
					}
					String n = m.getMethodInfo().isConstructor() ? clsName : m.getAlias();
					if (matches(n, q, matchCase)) {
						items.add(nameHit(top, m, "m", n + "(" + argList(m) + ")", cn.getFullName()));
					}
				}
				for (FieldNode f : cn.getFields()) {
					if (matches(f.getAlias(), q, matchCase)) {
						items.add(nameHit(top, f, "f", f.getAlias() + ": " + f.getType(), cn.getFullName()));
					}
				}
				if (items.size() >= MAX_NAME_HITS) {
					break outer;
				}
			}
		}
		return obj("items", items, "truncated", items.size() >= MAX_NAME_HITS);
	}

	private static List<ClassNode> withInners(ClassNode cn) {
		List<ClassNode> list = new ArrayList<>();
		list.add(cn);
		for (ClassNode inner : cn.getInnerClasses()) {
			list.addAll(withInners(inner));
		}
		return list;
	}

	private static boolean matches(String s, String q, boolean matchCase) {
		return (matchCase ? s : s.toLowerCase(Locale.ROOT)).contains(q);
	}

	private static String argList(MethodNode m) {
		StringBuilder sb = new StringBuilder();
		for (var t : m.getArgTypes()) {
			if (sb.length() > 0) {
				sb.append(", ");
			}
			String s = t.toString();
			sb.append(s.substring(s.lastIndexOf('.') + 1).replace('$', '.'));
		}
		return sb.toString();
	}

	private JsonObject nameHit(JavaClass top, ICodeNodeRef ref, String kind, String name, String owner) {
		int id = refSeq.incrementAndGet();
		refs.put(id, ref);
		return obj("cls", top.getRawName(), "ref", id, "kind", kind, "text", name, "name", owner);
	}

	private Object searchCode(String token, String query, boolean matchCase, AtomicBoolean cancelled) throws Exception {
		List<JavaClass> all = new ArrayList<>(classes.values());
		all.sort((a, b) -> a.getFullName().compareTo(b.getFullName()));
		String q = matchCase ? query : query.toLowerCase(Locale.ROOT);
		AtomicInteger done = new AtomicInteger();
		AtomicInteger found = new AtomicInteger();
		int threads = Math.max(1, Runtime.getRuntime().availableProcessors() - 1);
		ExecutorService workers = Executors.newFixedThreadPool(threads);
		try {
			List<java.util.concurrent.Future<?>> futures = new ArrayList<>();
			for (JavaClass c : all) {
				futures.add(workers.submit(() -> {
					if (cancelled.get() || found.get() >= MAX_CODE_HITS) {
						return;
					}
					String code;
					try {
						code = codeOf(c).getCodeStr();
					} catch (Throwable e) {
						return;
					}
					String hay = matchCase ? code : code.toLowerCase(Locale.ROOT);
					JsonArray items = new JsonArray();
					for (int i = hay.indexOf(q); i >= 0 && !q.isEmpty(); i = hay.indexOf(q, i + q.length())) {
						items.add(hit(c, code, i));
						if (found.incrementAndGet() >= MAX_CODE_HITS) {
							break;
						}
					}
					int n = done.incrementAndGet();
					if (items.size() > 0 || n % 50 == 0) {
						event("search", obj("token", token, "items", items, "done", n, "total", all.size()));
					}
				}));
			}
			for (var f : futures) {
				f.get();
			}
		} finally {
			workers.shutdownNow();
		}
		return obj("done", done.get(), "total", all.size(), "found", found.get(), "cancelled", cancelled.get());
	}

	// ---- export ----

	private Object export(JsonObject p) {
		File dir = new File(p.get("dir").getAsString());
		JadxArgs args = jadx.getArgs();
		args.setOutDir(dir);
		args.setOutDirSrc(new File(dir, "sources"));
		args.setOutDirRes(new File(dir, "resources"));
		jadx.save(500, (done, total) -> event("export", obj("done", done, "total", total)));
		return obj("dir", dir.getAbsolutePath());
	}

	// ---- io ----

	private void reply(long id, Object result) {
		JsonObject msg = new JsonObject();
		msg.addProperty("id", id);
		msg.add("result", gson.toJsonTree(result));
		send(msg);
	}

	private void event(String name, Object data) {
		JsonObject msg = new JsonObject();
		msg.addProperty("event", name);
		msg.add("data", gson.toJsonTree(data));
		send(msg);
	}

	private synchronized void send(JsonObject msg) {
		try {
			out.write(gson.toJson(msg).getBytes(StandardCharsets.UTF_8));
			out.write('\n');
			out.flush();
		} catch (Exception e) {
			System.exit(1);
		}
	}

	private JsonObject obj(Object... kv) {
		JsonObject o = new JsonObject();
		for (int i = 0; i < kv.length; i += 2) {
			o.add((String) kv[i], kv[i + 1] instanceof JsonElement ? (JsonElement) kv[i + 1] : gson.toJsonTree(kv[i + 1]));
		}
		return o;
	}
}
