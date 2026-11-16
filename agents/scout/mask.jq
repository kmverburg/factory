# Shared jq helpers: masking of secrets and normalising text so similar log lines group together.

def mask:
  gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"; "[email]")
  | gsub("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"; "[token]")
  | gsub("(?<k>bearer|basic)\\s+[A-Za-z0-9._~+/=-]{8,}"; "\(.k) [token]"; "i")
  | gsub("(?<k>(token|secret|password|passwd|api[_-]?key|authorization|cookie|session)[\"'\\]]?\\s*[:=]\\s*)[\"']?[^\\s\"',;&]+"; "\(.k)[masked]"; "i")
  | gsub("\\b(sk|pk|ghp|gho|ghs|ghu|github_pat|xox[a-z]|glpat)[-_][A-Za-z0-9_-]{10,}"; "[token]")
  | gsub("\\bAKIA[0-9A-Z]{12,}"; "[token]")
  | gsub("[A-Za-z0-9_+=]{32,}"; "[token]");

def events:
  if type == "array" then . else (.result.events.events // .events.events // .events // []) end;

def normalize_message:
  split("\n")[0]
  | gsub("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"; "<id>")
  | gsub("\\b[0-9a-fA-F]{8,}\\b"; "<id>")
  | gsub("[0-9]+"; "N")
  | gsub("\\s+"; " ")
  | .[0:200];
