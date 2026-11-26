# Builds issue-writer specs (agents/lib/issue-writer.sh) from what deps.sh found.
# Input: {project, repo, week, updates: [{dir, name, current, target, kind, reason}], security: [{dir, name, severity, direct,
# advisories: [{title, url}], fix: null | {version, major}, fix_text}], failed: [dir]}. Output: a JSON array of specs.
def sig($k): "Signature: `depsig-\(.repo)-\($k)`";
def where($d): if $d == "." then "root" else "`\($d)`" end;
def dirs(items): [items[].dir] | unique;
def table($rows): ($rows | map("- `\(.name)` \(.current) → \(.target) (\(.reason))") | join("\n"));
def per_dir(items; f): dirs(items) | map(. as $d | "**\(where($d))**\n" + ([items[] | select(.dir == $d)] | f)) | join("\n\n");
def notes($extra): "Check with `npm outdated` and `npm audit` by the weekly dependency check. " + $extra
  + (if (.failed | length) > 0 then "\n\nCould not check (install failed or no `package-lock.json`): " + (.failed | map(where(.)) | join(", ")) + "." else "" end);
. as $in
| [
  ( [.security[] | select(.fix != null)] as $sec
    | select(($sec | length) > 0)
    | {project, title: "Security fixes for dependencies (\(.week))", origin: "Agent", priority: 2,
       state: (if any($sec[]; .fix.major) then "todo" else "agent ready" end),
       labels: ["factory:dependencies"],
       goal: ("`npm audit` reports known security advisories in `\(.repo)`. Fix them, even if the fixed version is under 2 weeks old.\n\n"
         + per_dir($sec; map("- `\(.name)` (\(.severity)\(if .direct then ", direct dependency" else ", via another package" end)): \(.fix_text)"
             + ([.advisories[] | "\n  - [\(.title)](\(.url))"] | join(""))) | join("\n"))),
       acceptance: ["`npm audit` no longer reports the advisories above in " + (dirs($sec) | map(where(.)) | join(", ")) + ".",
                    "`package.json` and `package-lock.json` are updated together; tests, lint and build pass."],
       out_of_scope: ["Routine updates: those are in the weekly routine ticket."],
       agent_notes: notes("Why: security fix. Try `npm audit fix` first; where a fix needs a new major version (marked above) check what breaking changes apply."),
       footer: sig("security"), dedup_marker: "depsig-\($in.repo)-security"} ),
  ( [.updates[] | select(.kind != "major")] as $u
    | select(($u | length) > 0)
    | {project, title: "Dependency updates (\(.week))", origin: "Agent", state: "agent ready", labels: ["factory:dependencies"],
       goal: ("Minor and patch updates are available in `\(.repo)`. Only versions that have been published for at least 2 weeks are listed.\n\n"
         + per_dir($u; table(.))),
       acceptance: ["Every package above is at the version listed (exactly that version, not a newer one), in `package.json` and `package-lock.json`.",
                    "Tests, lint and build pass."],
       out_of_scope: ["Major version updates: those get their own ticket.", "Packages not listed above."],
       agent_notes: notes("Why: routine update. Install each as `npm install <package>@<version>` in the directory shown."),
       footer: sig("routine"), dedup_marker: "depsig-\($in.repo)-routine"} ),
  ( [.updates[] | select(.kind == "major")] as $u
    | select(($u | length) > 0)
    | {project, title: "Major dependency updates (\(.week))", origin: "Agent", state: "todo", labels: ["factory:dependencies"],
       goal: ("Major versions are available in `\(.repo)`. They can need code changes, so this ticket is in Todo: Koen decides whether to move it to Agent Ready, and which of these to do. Only versions that have been published for at least 2 weeks are listed.\n\n"
         + per_dir($u; table(.))),
       acceptance: ["The packages Koen picked are at the version listed, with code changes for the breaking changes.",
                    "Tests, lint and build pass."],
       out_of_scope: ["Minor and patch updates: those are in the weekly routine ticket."],
       agent_notes: notes("Why: new major version. Read each package's changelog or migration guide first."),
       footer: sig("major"), dedup_marker: "depsig-\($in.repo)-major"} )
  ]
