default:
    @just --list

# Install cc_pure as the Claude Code statusline
[group('setup')]
install: build-release
    mkdir -p ~/.claude
    mv zig-out/bin/cc_pure ~/.claude/
    @if [ ! -f ~/.claude/settings.json ]; then echo "{}" > ~/.claude/settings.json; fi
    jq '.statusLine = {type: "command", command: "~/.claude/cc_pure"}' ~/.claude/settings.json > ~/.claude/settings.json.tmp && mv ~/.claude/settings.json.tmp ~/.claude/settings.json

# Build a release version
[group('build')]
build-release:
    zig build -Doptimize=ReleaseSafe
