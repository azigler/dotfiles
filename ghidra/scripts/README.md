# ghidra/scripts/

Ghidra headless scripts. `./sync.sh ghidra` symlinks this directory to
`$HOME/ghidra_scripts` — Ghidra's default user script directory.

**Empty on purpose.** Ghidra is **not installed** on this box and is **not in
apt**; it needs a manual release-zip install (~400 MB, plus ~2 GB of
workspaces). Java 21 is present, so it will run once unpacked. Docker is a
viable delivery path. The full inventory — versions, what else is absent, the
complete `analyzeHeadless` flag set — lives in one place and only one place:

    agents/skills/cleanroom/reference/tool-shelf.md

## The two things to know before you write a script here

**1. `-scriptPath` resolves scripts BY NAME, not by path.** This is the flag
people get wrong. You pass a *search directory* and then name the script as a
bare filename; a path in the `-postScript` position does not work. The script
must also be in the default package (no `package` declaration).

```bash
<GHIDRA>/support/analyzeHeadless <project_dir> <project_name> \
  -import <binary> -deleteProject \
  -scriptPath "$HOME/ghidra_scripts" \
  -postScript MyScript.java <args…>
```

`$GHIDRA_HOME` / `$USER_HOME` appearing inside a script path must be
backslash-escaped.

**2. The durable automation pattern is script-writes-JSON → agent-reads-JSON.**
The script writes a JSON file to a temp dir; `-deleteProject` tears the project
down; the agent reads the JSON back afterwards. Do **not** scrape
`analyzeHeadless` console output or the `-scriptlog` file — that text is
human-facing, unversioned, and changes between Ghidra releases, so a parse of
it fails by returning something plausible rather than by erroring.

## And the thing to remember about the output

Decompiler output is **spec input, never an oracle.** It tells you what the
code probably does. Only execution tells you what it does.
