# Reads a field of a Workers Logs event and applies {key, operation, value} conditions locally.

def getf($k):
  if ($k | startswith("$metadata.")) then (."$metadata" // {})[$k[10:]]
  elif ((.source | type) == "object") and (.source | has($k)) then .source[$k]
  elif has($k) then .[$k]
  elif ((."$metadata" | type) == "object") and (."$metadata" | has($k)) then ."$metadata"[$k]
  else null end;
def num: if type == "string" then (tonumber? // null) else . end;
def cond($c):
  getf($c.key) as $v
  | if $c.operation == "eq" then $v == $c.value
    elif $c.operation == "neq" then $v != $c.value
    else ($v | num) as $x | ($x | type) == "number" and (
      if $c.operation == "gt" then $x > $c.value elif $c.operation == "gte" then $x >= $c.value
      elif $c.operation == "lt" then $x < $c.value elif $c.operation == "lte" then $x <= $c.value
      else false end) end;
def matches($cs): . as $e | all($cs[]?; . as $c | $e | cond($c));
