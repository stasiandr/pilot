#!/bin/bash
# Сборка, которую можно отдать другому: release, подпись Developer ID,
# нотаризация Apple и zip, который открывается без предупреждений Gatekeeper.
#
#   ./dist.sh               → dist/Pilot-<версия>-<коммит>-arm64.zip
#   ./dist.sh --publish     → то же и релиз v<версия> там, откуда сборка
#                             обновляется (PilotUpdateSource в Info.plist)
#
# Выпустить новую версию:
#   1. Поднять CFBundleShortVersionString в Resources/Info.plist, закоммитить
#      и запушить.
#   2. ./dist.sh --publish
# Релиз с тегом v<версия> и zip'ом — то, что Pilot у всех находит сам
# (Updater.swift): над редактором появляется плашка «Обновить сейчас».
# Имя архива заканчивается архитектурой — по ней Pilot берёт свой.
#
# Источник github:owner/repo — релиз через gh. Источник
# gitlab:host/group/project — zip в Generic Packages проекта и GitLab Release
# со ссылкой на него; токен (api) — GITLAB_TOKEN или тот, что Pilot хранит
# в связке ключей для этого хоста.
#
# Один раз до первого запуска:
#   1. Сертификат «Developer ID Application» в связке ключей
#      (Xcode → Settings → Accounts → Manage Certificates → +).
#   2. Доступ к нотаризации под именем профиля pilot-notary:
#      xcrun notarytool store-credentials pilot-notary \
#          --apple-id <почта> --team-id <TEAMID>
#      (пароль — app-specific, с account.apple.com)
#
# SIGN_ID и NOTARY_PROFILE переопределяют сертификат и профиль.
set -euo pipefail

cd "$(dirname "$0")"

PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
SOURCE="$(/usr/libexec/PlistBuddy -c 'Print PilotUpdateSource' Resources/Info.plist 2>/dev/null || echo github:stasiandr/pilot)"
KIND="${SOURCE%%:*}"
TARGET="${SOURCE#*:}"

gitlab_api() {   # gitlab_api МЕТОД путь [curl-аргументы…]
    local method="$1" path="$2"; shift 2
    curl -sS --fail-with-body -X "$method" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "https://$GITLAB_HOST/api/v4/projects/$GITLAB_PROJECT_ID$path" "$@"
}

# Всё, из-за чего релиз не выйдет, — до сборки и нотаризации, а не после.
if [[ $PUBLISH == 1 ]]; then
    case "$KIND" in
    github)
        if ! command -v gh > /dev/null; then
            echo "Нужен gh (brew install gh; gh auth login)" >&2
            exit 1
        fi
        if gh release view "v$VERSION" --repo "$TARGET" > /dev/null 2>&1; then
            echo "Релиз v$VERSION уже есть — поднимите CFBundleShortVersionString в Resources/Info.plist" >&2
            exit 1
        fi
        ;;
    gitlab)
        GITLAB_HOST="${TARGET%%/*}"
        GITLAB_PROJECT_ID="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${TARGET#*/}")"
        GITLAB_TOKEN="${GITLAB_TOKEN:-$(security find-generic-password -s dev.local.pilot.gitlab -a "$GITLAB_HOST" -w 2>/dev/null || true)}"
        if [[ -z "$GITLAB_TOKEN" ]]; then
            echo "Нужен токен GitLab с правом api: GITLAB_TOKEN=… ./dist.sh --publish" >&2
            exit 1
        fi
        if gitlab_api GET "/releases/v$VERSION" > /dev/null 2>&1; then
            echo "Релиз v$VERSION уже есть — поднимите CFBundleShortVersionString в Resources/Info.plist" >&2
            exit 1
        fi
        ;;
    *)
        echo "PilotUpdateSource «$SOURCE» не понять: github:owner/repo или gitlab:host/group/project" >&2
        exit 1
        ;;
    esac
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Есть незакоммиченные изменения — релиз собирается из коммита" >&2
        exit 1
    fi
    git fetch -q --all
    if [[ -z "$(git branch -r --contains HEAD)" ]]; then
        echo "Коммит $(git rev-parse --short HEAD) не запушен — сначала git push" >&2
        exit 1
    fi
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-pilot-notary}"
if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [[ -z "$SIGN_ID" ]]; then
    echo "Нет сертификата Developer ID Application — см. шапку dist.sh" >&2
    exit 1
fi
export SIGN_ID

./build.sh release

NAME="Pilot-$VERSION-$(git rev-parse --short HEAD)-$(uname -m)"
mkdir -p dist
ZIP="dist/$NAME.zip"
rm -f "$ZIP"

echo "==> отправляю на нотаризацию (обычно 1–5 минут)"
ditto -c -k --keepParent Pilot.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    | tee .build/notary.log
if ! grep -q "status: Accepted" .build/notary.log; then
    ID="$(sed -n 's/^ *id: //p' .build/notary.log | head -1)"
    echo "Нотаризация не прошла. Подробности:" >&2
    echo "   xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi

# Билет вшивается в бандл, чтобы Gatekeeper не ходил за ним в сеть,
# поэтому zip пересобирается уже со степлированным приложением.
xcrun stapler staple Pilot.app
rm -f "$ZIP"
ditto -c -k --keepParent Pilot.app "$ZIP"
spctl --assess --type execute -v Pilot.app

echo
echo "Готово: $(pwd)/$ZIP"

if [[ $PUBLISH == 1 ]]; then
    echo "==> публикую релиз v$VERSION ($SOURCE)"
    FILE="$(basename "$ZIP")"
    if [[ "$KIND" == github ]]; then
        gh release create "v$VERSION" "$ZIP" --repo "$TARGET" \
            --target "$(git rev-parse HEAD)" \
            --title "Pilot $VERSION" \
            --generate-notes
    else
        gitlab_api PUT "/packages/generic/pilot/$VERSION/$FILE" --upload-file "$ZIP" > /dev/null
        URL="https://$GITLAB_HOST/api/v4/projects/$GITLAB_PROJECT_ID/packages/generic/pilot/$VERSION/$FILE"
        gitlab_api POST "/releases" -H "Content-Type: application/json" --data @- > /dev/null <<JSON
{"tag_name": "v$VERSION", "ref": "$(git rev-parse HEAD)", "name": "Pilot $VERSION",
 "assets": {"links": [{"name": "$FILE", "url": "$URL", "link_type": "package"}]}}
JSON
        echo "Готово: https://$GITLAB_HOST/${TARGET#*/}/-/releases/v$VERSION"
    fi
fi
