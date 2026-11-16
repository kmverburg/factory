# Formatting of metric values for tickets and reports.
def fmtv($v; $unit):
  if $unit == "rate" then "\(($v * 1000 | round) / 10)%"
  elif $unit == "ms" then "\($v | round) ms"
  else "\((($v * 100 | round) / 100))\(if $unit == "" then "" else " " + $unit end)" end;
def fmt: fmtv(.value; .unit);
