# The buffer is just a linked list of strings.

# Implementation uses a gap buffer with explicit undo stack.

import strutils
from unicode import reversed, lastRune, isCombining

when false:
  type
    Style* = object
      font: FontPtr
      bold, italic: bool
      size: int

    Cell* = object
      style: StyleIdx
      w: byte
      rune: Rune

type
  ActionKind = enum
    ins, insFinished, del, delFinished

  Action = object
    k: ActionKind
    pos: int
    word: string

  Buffer* = ref object
    cursor: int
    front, back: string
    actions: seq[Action]
    undoIdx: int
    next*, prev*: Buffer
    changed*: bool
    heading*: string
    filename*: string

proc newBuffer*(heading: string): Buffer =
  new(result)
  result.front = ""
  result.back = ""
  result.filename = ""
  result.heading = heading
  result.actions = @[]

proc loadFromFile*(b: Buffer; filename: string) =
  b.filename = filename

proc clear*(result: Buffer) =
  result.front.setLen 0
  result.back.setLen 0
  result.actions.setLen 0

proc contents*(b: Buffer): string =
  result = newStringOfCap(b.front.len + b.back.len + 1)
  result.add b.front
  result.add '|'
  for i in countdown(b.back.len-1, 0):
    result.add b.back[i]

proc fullText*(b: Buffer): string =
  result = newStringOfCap(b.front.len + b.back.len)
  result.add b.front
  for i in countdown(b.back.len-1, 0):
    result.add b.back[i]

template edit(b: Buffer) =
  b.undoIdx = b.actions.len-1

proc prepareForEdit(b: Buffer) =
  if b.cursor < b.front.len:
    for i in countup(b.cursor, b.front.len-1):
      b.back.add(b.front[i])
    setLen(b.front, b.cursor)
  elif b.cursor > b.front.len:
    let chars = max(b.cursor - b.front.len, 0)
    var took = 0
    for i in countdown(b.back.len-1, max(b.back.len-chars, 0)):
      b.front.add(b.back[i])
      inc took
    setLen(b.back, b.back.len - took)

proc left*(b: Buffer; shift: bool) =
  if b.cursor > 0:
    b.cursor -= 1
    prepareForEdit(b)

proc right*(b: Buffer; shift: bool) =
  if b.cursor < b.front.len+b.back.len:
    b.cursor += 1
    prepareForEdit(b)

proc up*(b: Buffer; shift: bool) =
  while b.cursor >= 0:
    b.cursor -= 1
    if b.front[b.cursor] == '\L': break
  if b.cursor < 0: b.cursor = 0
  prepareForEdit(b)

proc down*(b: Buffer; shift: bool) =
  discard

proc rawInsert*(b: Buffer; s: string) =
  b.front.add s
  b.cursor += s.len

proc insert*(b: Buffer; s: string) =
  prepareForEdit(b)
  setLen(b.actions, clamp(b.undoIdx+1, 0, b.actions.len))
  if b.actions.len > 0 and b.actions[^1].k == ins:
    b.actions[^1].word.add s
  else:
    b.actions.add(Action(k: ins, pos: b.cursor, word: s))
  if s[^1] in Whitespace: b.actions[^1].k = insFinished
  edit(b)
  rawInsert(b, s)

proc rawBackspace(b: Buffer): string =
  var x = 0
  while true:
    let (r, L) = lastRune(b.front, b.front.len-1-x)
    inc(x, L)
    if L > 1 and isCombining(r): discard
    else: break
  # we need to reverse this string here:
  result = newString(x)
  var j = 0
  for i in countdown(b.front.len-1, b.front.len-x):
    result[j] = b.front[i]
    inc j
  b.cursor -= result.len
  b.front.setLen(b.cursor)

proc backspace*(b: Buffer) =
  if b.cursor <= 0: return
  prepareForEdit(b)
  setLen(b.actions, clamp(b.undoIdx+1, 0, b.actions.len))
  let ch = b.rawBackspace
  if b.actions.len > 0 and b.actions[^1].k == del:
    b.actions[^1].word.add ch
  else:
    b.actions.add(Action(k: del, pos: b.cursor, word: ch))
  edit(b)
  if ch.len == 1 and ch[0] in Whitespace: b.actions[^1].k = delFinished

proc applyUndo(b: Buffer; a: Action) =
  if a.k <= insFinished:
    b.cursor = a.pos + a.word.len
    prepareForEdit(b)
    b.cursor = a.pos
    # reverse op of insert is delete:
    b.front.setLen(b.cursor)
  else:
    b.cursor = a.pos
    prepareForEdit(b)
    # reverse op of delete is insert:
    for i in countdown(a.word.len-1, 0):
      b.front.add a.word[i]
    b.cursor += a.word.len

proc applyRedo(b: Buffer; a: Action) =
  if a.k <= insFinished:
    b.cursor = a.pos
    prepareForEdit(b)
    # reverse op of delete is insert:
    for i in countup(0, a.word.len-1):
      b.front.add a.word[i]
    b.cursor += a.word.len
  else:
    b.cursor = a.pos + a.word.len
    prepareForEdit(b)
    b.cursor = a.pos
    # reverse op of insert is delete:
    b.front.setLen(b.cursor)

proc undo*(b: Buffer) =
  when defined(debugUndo):
    echo "undo ----------------------------------------"
    for i, x in b.actions:
      if i == b.undoIdx:
        echo x, "*"
      else:
        echo x
  if b.undoIdx >= 0 and b.undoIdx < b.actions.len:
    applyUndo(b, b.actions[b.undoIdx])
    dec(b.undoIdx)

proc redo*(b: Buffer) =
  when defined(debugUndo):
    echo "redo ----------------------------------------"
    inc(b.undoIdx)
    for i, x in b.actions:
      if i == b.undoIdx:
        echo x, "*"
      else:
        echo x
  if b.undoIdx >= 0 and b.undoIdx < b.actions.len:
    applyRedo(b, b.actions[b.undoIdx])
  else:
    dec b.undoIdx