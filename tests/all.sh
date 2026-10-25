#!/usr/bin/env bash
# Local checks. Everything here runs against the checkout, never the live shell.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -m unittest discover -s tests -v
node tests/model.test.js
python3 -m py_compile bin/omarchy-agent-limits-sync

# Qt5's qmllint cannot parse Qt6 QML at all, so pick a Qt6 binary explicitly
# instead of trusting whatever `qmllint` is first on PATH.
qmllint=""
for candidate in /usr/lib/qt6/bin/qmllint qmllint6 "$(command -v qmllint || true)"; do
  [ -x "$candidate" ] || continue
  case "$("$candidate" --version 2>&1 | head -1)" in
    1.*) continue ;;  # Qt5
  esac
  qmllint="$candidate"
  break
done
if [ -z "$qmllint" ]; then
  echo "qmllint (Qt6) not found; skipping QML lint" >&2
else
  shell_path="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
  # Warnings are style advice from qmllint (unqualified singleton access, and
  # the entry point shadowing qs.Ui.Panel the way every first-party plugin
  # does); only hard errors fail the run.
  output="$("$qmllint" -I "$shell_path" Panel.qml Dashboard.qml EmbeddedPage.qml \
    Service.qml PlainText.qml DailyChart.qml 2>&1 || true)"
  echo "$output" | grep -v '^$' | grep -c 'Warning:' | sed 's/^/qmllint warnings: /' || true
  if echo "$output" | grep -q 'Error:'; then
    echo "$output" | grep 'Error:'
    exit 1
  fi
fi

omarchy plugin validate .
