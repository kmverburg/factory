# Which versions of a package may be proposed. Input: {current, times: {version: iso8601 publish time}, now: epoch seconds,
# min_age_days}. Output: {same_major, major}: the highest stable version above `current` that is at least min_age_days old,
# within the current major (minor/patch update) and in a higher major. null when there is none. Pre-releases are never proposed.
def ver: if type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$") then split(".") | map(tonumber) else null end;
def secs: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
(.current | ver) as $cur
| (.now - .min_age_days * 86400) as $cutoff
| [ (.times // {}) | to_entries[] | (.key | ver) as $v | select($v != null)
    | select((.value | type) == "string" and (.value | secs) <= $cutoff) | {s: .key, v: $v} ] as $ok
| if $cur == null then {same_major: null, major: null}
  else {
    same_major: ([$ok[] | select(.v[0] == $cur[0] and .v > $cur)] | max_by(.v) | .s // null),
    major: ([$ok[] | select(.v[0] > $cur[0])] | max_by(.v) | .s // null)
  } end
