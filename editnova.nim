
import strutils, critbits
from parseutils import parseInt
from os import extractFilename, splitFile, expandFilename, cmpPaths, `/`
import sdl2, sdl2/ttf, prims
import buffertype, buffer, styles, unicode, highlighters, console
import languages, themes, nimscriptsupport, tabbar, scrollbar, indexer

when defined(windows):
  import dialogs


# TODO:
#  - better line wrapping
#  - regex search&replace; nah, just make it scriptable properly instead
#  - nimsuggest integration
#  - show declarations in a minimap
#  - draw gradient for scrollbar
#  - debugger support!
#  - make F-keys scriptable
#  - idea: switch between header and implemenation file for C/C++

# Optional:
#  - large file handling
#  - highlighting of substring occurences
# Optimizations:
#  - cache font renderings

const
  readyMsg = "Ready."

  controlKey = when defined(macosx): KMOD_GUI or KMOD_CTRL else: KMOD_CTRL


type
  EditorState = enum
    requestedNothing,
    requestedShutdown, requestedShutdownNext,
    requestedReplace

  Editor = ref object
    focus, main, prompt, console, autocomplete: Buffer # focus points to either
                                                       # main, prompt or console
    mainRect, promptRect, consoleRect: Rect
    statusMsg: string
    uiFont: FontPtr

    renderer: RendererPtr
    window: WindowPtr
    theme: InternalTheme
    screenW, screenH: cint
    buffersCounter: int
    con, promptCon: Console
    mgr: StyleManager
    cfgColors, cfgActions: string
    project: string
    state: EditorState
    bar: TabBar
    ticker: int
    indexer: CritbitTree[int]


template unkownName(): untyped = "unknown-" & $ed.buffersCounter & ".txt"

proc setDefaults(ed: Editor; fontM: var FontManager) =
  ed.screenW = cint(650)
  ed.screenH = cint(780)
  ed.statusMsg = readyMsg

  ed.main = newBuffer(unkownName(), addr ed.mgr)
  ed.prompt = newBuffer("", addr ed.mgr)
  ed.console = newBuffer("", addr ed.mgr)
  ed.console.lang = langConsole

  ed.autocomplete = newBuffer("", addr ed.mgr)

  ed.buffersCounter = 1
  ed.main.next = ed.main
  ed.main.prev = ed.main
  ed.focus = ed.main

  ed.con = newConsole(ed.console)
  ed.con.insertPrompt()
  ed.promptCon = newConsole(ed.prompt)

  ed.uiFont = fontM.fontByName("Arial", 12)
  ed.theme.active[true] = parseColor"#FFA500"
  ed.theme.active[false] = parseColor"#C0C0C0"
  #ed.theme.bg = parseColor"#0c090a"
  ed.theme.bg = parseColor"#292929"
  ed.theme.fg = parseColor"#fafafa"
  ed.theme.cursor = ed.theme.fg
  ed.cfgColors = os.getAppDir() / "nimscript" / "colors.nims"
  ed.cfgActions = os.getAppDir() / "nimscript" / "actions.nims"

proc destroy(ed: Editor) =
  destroyRenderer ed.renderer
  destroy ed.window

template insertBuffer(head, n) =
  n.next = head
  n.prev = head.prev
  head.prev.next = n
  head.prev = n
  head = n
  inc ed.buffersCounter

template removeBuffer(n) =
  if ed.buffersCounter > 1:
    let nxt = n.next
    if n == ed.bar:
      ed.bar = nxt
    if n == ed.focus:
      ed.focus = nxt
    n.next.prev = n.prev
    n.prev.next = n.next
    n = nxt
    dec ed.buffersCounter

proc openTab(ed: Editor; filename: string): bool {.discardable.} =
  var fullpath: string
  try:
    fullpath = expandFilename(filename)
  except OSError:
    ed.statusMsg = getCurrentExceptionMsg()
    return false

  ed.statusMsg = readyMsg
  # be intelligent:
  var it = ed.main
  while true:
    if cmpPaths(it.filename, fullpath) == 0:
      # just bring the existing tab into focus:
      ed.main = it
      return true
    it = it.next
    if it == ed.main: break

  let x = newBuffer(fullpath.extractFilename, addr ed.mgr)
  try:
    x.loadFromFile(fullpath)
    insertBuffer(ed.main, x)
    ed.focus = ed.main
    result = true
  except IOError:
    ed.statusMsg = "cannot open: " & filename


include prompt

proc hasConsole(ed: Editor): bool = ed.consoleRect.x >= 0

proc layout(ed: Editor) =
  let yGap = ed.theme.uiYGap
  let xGap = ed.theme.uiXGap
  let fontSize = ed.theme.editorFontSize.int
  ed.mainRect = rect(15, yGap*3+fontSize,
                        ed.screenW - 15*2,
                        ed.screenH - 7*fontSize - yGap*2)
  ed.promptRect = rect(15, fontSize+yGap*3 + ed.screenH - 7*fontSize,
                          ed.screenW - 15*2,
                          fontSize+yGap*2)
  if ed.screenW > ed.theme.consoleAfter and ed.theme.consoleAfter >= 0:
    # enable the console:
    let d = ed.screenW * (100 - ed.theme.consoleWidth.cint) div 100
    ed.mainRect.w = d - 15
    ed.consoleRect = ed.mainRect
    ed.consoleRect.w = ed.screenW - d - 15
    ed.consoleRect.x += ed.mainRect.w + xGap.cint*2
  else:
    # disable console:
    ed.consoleRect.x = -1
    # if the console is disabled, it cannot have the focus:
    if ed.focus == ed.console: ed.focus = ed.main

proc withUnsavedChanges(start: Buffer): Buffer =
  result = start
  while true:
    if result.changed: return result
    result = result.next
    if result == start: break
  return nil

proc displayNL(s: string): string =
  if s.len == 0: return "LF"
  case s
  of "\C\L": return "CR-LF"
  of "\C": return "CR"
  else: return "LF"

proc filelistFile(): string =
  const dot = when defined(windows): "" else: "."
  os.getConfigDir() / dot & "aporia_pro_filelist.txt"

proc saveOpenTabs(ed: Editor) =
  var f: File
  if open(f, filelistFile(), fmWrite):
    var it = ed.main.prev
    while it != nil:
      if it.filename.len > 0:
        f.writeline(it.filename, "\t", it.getLine, "\t", it.getColumn)
      if it == ed.main: break
      it = it.prev
    f.close()

proc loadOpenTabs(ed: Editor) =
  var oldRoot = ed.main
  var f: File
  if open(f, filelistFile()):
    for line in lines(f):
      let x = line.split('\t')
      if ed.openTab(x[0]):
        gotoLine(ed.main, parseInt(x[1]), parseInt(x[2]))
        ed.focus = ed.main
        if oldRoot != nil:
          removeBuffer(oldRoot)
          oldRoot = nil
    f.close()

proc handleF5(ed: Editor) =
  if hasConsole(ed):
    upPressed(ed.con)
    enterPressed(ed.con)
  else:
    ed.statusMsg = "No console open. Make the window wider."

const
  DefaultTimeOut = 500.cint
  TimeoutsPerSecond = 1000 div DefaultTimeOut

proc tick(ed: Editor) =
  inc ed.ticker
  # run the index every 500ms. It's incremental and fast.
  indexBuffers(ed.indexer, ed.main)

  # periodic events. Every 5 minutes we save the list of open tabs.
  if ed.ticker > TimeoutsPerSecond*60*5:
    ed.ticker = 0
    saveOpenTabs(ed)

proc mainProc(ed: Editor) =
  var fontM: FontManager = @[]
  setDefaults(ed, fontM)
  setupNimscript(ed.cfgColors, ed.cfgActions)

  template loadTheme() =
    loadTheme(ed.cfgColors, ed.theme, ed.mgr, fontM)
    ed.uiFont = fontM.fontByName(ed.theme.uiFont, ed.theme.uiFontSize)
    ed.theme.uiFontPtr = ed.uiFont
    ed.theme.editorFontPtr = fontM.fontByName(ed.theme.editorFont,
                                              ed.theme.editorFontSize)

  loadTheme()

  ed.window = createWindow("Aporia Pro", 10, 30, ed.screenW, ed.screenH,
                            SDL_WINDOW_RESIZABLE or SDL_WINDOW_MAXIMIZED)
  ed.window.getSize(ed.screenW, ed.screenH)
  ed.renderer = createRenderer(ed.window, -1, Renderer_Software)
  ed.theme.renderer = ed.renderer
  ed.bar = ed.main
  template prompt: expr = ed.prompt
  template focus: expr = ed.focus
  template main: expr = ed.main
  template renderer: expr = ed.renderer
  template console: expr = ed.console

  var blink = 1
  var clickOnFilename = false
  layout(ed)
  loadOpenTabs(ed)
  while true:
    # we need to wait for the next frame until the cursor has moved to the
    # right position:
    if clickOnFilename:
      clickOnFilename = false
      let (file, line, col) = console.extractFilePosition()
      if file.len > 0 and line > 0:
        if ed.openTab(file):
          gotoLine(main, line, col)
          focus = main

    var rawMainRect = ed.mainRect
    rawMainRect.w -= scrollBarWidth(main)

    var e = Event(kind: UserEvent5)
    # if we have an external process running in the background, we have a
    # much shorter timeout. Nevertheless this should not affect our blinking
    # speed:
    let timeout = if ed.con.processRunning: 100.cint else: DefaultTimeOut
    if waitEventTimeout(e, timeout) == SdlSuccess:
      case e.kind
      of QuitEvent:
        saveOpenTabs(ed)
        ed.state = requestedShutdown
        let b = withUnsavedChanges(main)
        if b == nil: break
        main = b
        ed.askForQuitTab()
      of WindowEvent:
        let w = e.window
        if w.event == WindowEvent_Resized:
          ed.screenW = w.data1
          ed.screenH = w.data2
          layout(ed)
      of MouseButtonDown:
        let w = e.button
        let p = point(w.x, w.y)
        if ed.mainRect.contains(p):
          if focus == main and rawMainRect.contains(p):
            main.setCursorFromMouse(ed.mainRect, p, w.clicks.int)
          else:
            focus = main
        elif ed.promptRect.contains(p):
          if focus == prompt:
            prompt.setCursorFromMouse(ed.promptRect, p, w.clicks.int)
          else:
            focus = prompt
        elif hasConsole(ed) and ed.consoleRect.contains(p):
          if focus == console:
            console.setCursorFromMouse(ed.consoleRect, p, w.clicks.int)
            clickOnFilename = w.clicks.int >= 2
          else:
            focus = console
      of MouseWheel:
        let w = e.wheel
        var p: Point
        discard getMouseState(p.x, p.y)
        let a = if hasConsole(ed) and ed.consoleRect.contains(p): console
                else: focus
        a.scrollLines(-w.y*3)
      of TextInput:
        let w = e.text
        # surpress CTRL+Space:
        var surpress = false
        if w.text[0] == ' ' and w.text[1] == '\0':
          let keys = getKeyboardState()
          if keys[SDL_SCANCODE_LCTRL.int] == 1 or
             keys[SDL_SCANCODE_RCTRL.int] == 1:
            surpress = true
        if not surpress:
          if focus==ed.autocomplete:
            # delegate to main, but keep the focus on the autocomplete!
            main.insertSingleKey($w.text)
            populateBuffer(ed.indexer, ed.autocomplete, main.getWordPrefix())
          else:
            focus.insertSingleKey($w.text)
      of KeyDown:
        let w = e.key
        case w.keysym.scancode
        of SDL_SCANCODE_BACKSPACE:
          focus.backspace()
        of SDL_SCANCODE_DELETE:
          focus.deleteKey()
        of SDL_SCANCODE_RETURN:
          if focus==main:
            main.insertEnter()
          elif focus==prompt:
            if ed.runCmd(prompt.fullText):
              saveOpenTabs(ed)
              break
          elif focus==console:
            enterPressed(ed.con)
          elif focus==ed.autocomplete:
            indexer.selected(ed.autocomplete, main)
            focus = main
        of SDL_SCANCODE_ESCAPE:
          if (w.keysym.modstate and KMOD_SHIFT) != 0:
            if focus == console or not ed.hasConsole: focus = main
            else: focus = console
          else:
            if focus==main: focus = prompt
            else: focus = main
        of SDL_SCANCODE_RIGHT:
          if (w.keysym.modstate and KMOD_SHIFT) != 0:
            focus.selectRight((w.keysym.modstate and controlKey) != 0)
          else:
            focus.deselect()
            focus.right((w.keysym.modstate and controlKey) != 0)
        of SDL_SCANCODE_LEFT:
          if (w.keysym.modstate and KMOD_SHIFT) != 0:
            focus.selectLeft((w.keysym.modstate and controlKey) != 0)
          else:
            focus.deselect()
            focus.left((w.keysym.modstate and controlKey) != 0)
        of SDL_SCANCODE_DOWN:
          if (w.keysym.modstate and KMOD_SHIFT) != 0:
            focus.selectDown((w.keysym.modstate and controlKey) != 0)
          elif focus==prompt:
            ed.promptCon.downPressed()
          elif focus == console:
            ed.con.downPressed()
          else:
            focus.deselect()
            focus.down((w.keysym.modstate and controlKey) != 0)
        of SDL_SCANCODE_UP:
          if (w.keysym.modstate and KMOD_SHIFT) != 0:
            focus.selectUp((w.keysym.modstate and controlKey) != 0)
          elif focus==prompt:
            ed.promptCon.upPressed()
          elif focus == console:
            ed.con.upPressed()
          else:
            focus.deselect()
            focus.up((w.keysym.modstate and controlKey) != 0)
        of SDL_SCANCODE_TAB:
          if (w.keysym.modstate and controlKey) != 0:
            main = main.next
            focus = main
          elif focus == main:
            if (w.keysym.modstate and KMOD_SHIFT) != 0:
              main.shiftTabPressed()
            else:
              main.tabPressed()
          elif focus == console:
            ed.con.tabPressed()
          elif focus == prompt:
            ed.promptCon.tabPressed()
        of SDL_SCANCODE_F1:
          if focus == console or not ed.hasConsole: focus = main
          else: focus = console
        of SDL_SCANCODE_F5:
          handleF5(ed)
        else: discard
        if (w.keysym.modstate and controlKey) != 0:
          if w.keysym.sym == ord(' '):
            focus = ed.autocomplete
            populateBuffer(ed.indexer, ed.autocomplete, main.getWordPrefix())
          elif w.keysym.sym == ord('z'):
            # CTRL+Z: undo
            # CTRL+shift+Z: redo
            if (w.keysym.modstate and KMOD_SHIFT) != 0:
              focus.redo
            else:
              focus.undo
          elif w.keysym.sym == ord('a'):
            focus.selectAll()
          elif w.keysym.sym == ord('b'):
            ed.con.sendBreak()
          elif w.keysym.sym == ord('e'):
            ed.runScriptCmd()
          elif w.keysym.sym == ord('f'):
            ed.findCmd()
          elif w.keysym.sym == ord('g'):
            ed.gotoCmd()
          elif w.keysym.sym == ord('h'):
            ed.replaceCmd()
          elif w.keysym.sym == ord('x'):
            let text = focus.getSelectedText
            if text.len > 0:
              focus.removeSelectedText()
              discard sdl2.setClipboardText(text)
          elif w.keysym.sym == ord('c'):
            let text = focus.getSelectedText
            if text.len > 0:
              discard sdl2.setClipboardText(text)
          elif w.keysym.sym == ord('v'):
            let text = sdl2.getClipboardText()
            focus.insert($text)
            freeClipboardText(text)
          elif w.keysym.sym == ord('u'):
            main.markers.setLen 0
            if ed.state == requestedReplace: ed.state = requestedNothing
            highlightEverything(focus)
          elif w.keysym.sym == ord('o'):
            when defined(windows):
              let previousLocation =
                if main.filename.len > 0: main.filename.splitFile.dir
                else: ""
              let toOpen = chooseFilesToOpen(nil, previousLocation)
              for p in toOpen:
                ed.openTab(p)
              focus = main
          elif w.keysym.sym == ord('s'):
            main.save()
            if cmpPaths(main.filename, ed.cfgColors) == 0:
              loadTheme()
            elif cmpPaths(main.filename, ed.cfgActions) == 0:
              loadActions(ed.cfgActions)
            ed.statusMsg = readyMsg
          elif w.keysym.sym == ord('n'):
            let x = newBuffer(unkownName(), addr ed.mgr)
            insertBuffer(main, x)
            focus = main
          elif w.keysym.sym == ord('q'):
            if not main.changed:
              removeBuffer(main)
            else:
              ed.askForQuitTab()
      else: discard
      # keydown means show the cursor:
      blink = 0
    else:
      # timeout, so update the blinking:
      if timeout == 500:
        blink = 1-blink
        tick(ed)
      else:
        inc blink
        if blink >= 5:
          blink = 0
          tick(ed)
    if ed.state == requestedShutdownNext:
      ed.state = requestedShutdown
      let b = withUnsavedChanges(main)
      if b == nil: break
      main = b
      ed.askForQuitTab()

    update(ed.con)
    clear(renderer)

    # position of the tab bar hard coded for now as we don't want to adapt it
    # to the main margin (tried it, is ugly):
    let activeTab = drawTabBar(ed.bar, ed.theme, 47, ed.screenW,
                               e, ed.main)
    if activeTab != nil:
      main = activeTab
      focus = main

    ed.theme.draw(main, rawMainRect, (blink==0 and focus==main) or
                                      focus==ed.autocomplete,
                  ed.theme.showLines)
    let scrollTo = drawScrollBar(main, ed.theme, e, ed.mainRect)
    if scrollTo >= 0:
      scrollLines(main, scrollTo-main.firstLine)

    var mainBorder = ed.mainRect
    mainBorder.x = spaceForLines(main, ed.theme) + ed.theme.uiXGap.cint + 2
    mainBorder.w = ed.mainRect.x + ed.mainRect.w - 1 - mainBorder.x
    ed.theme.drawBorder(mainBorder, focus==main)

    if focus == ed.autocomplete:
      var autoRect = mainBorder
      autoRect.x += 10
      autoRect.w -= 20
      autoRect.y = cint(main.cursorDim.y + main.cursorDim.h + 10)
      autoRect.h = min(ed.mainRect.y + ed.mainRect.h - autoRect.y, 400)
      ed.theme.drawBorderBox(autoRect, true)
      ed.theme.drawAutoComplete(ed.autocomplete, autoRect)

    if ed.hasConsole:
      ed.theme.draw(console, ed.consoleRect,
                    blink==0 and focus==console)
      ed.theme.drawBorder(ed.consoleRect, focus==console)

    ed.theme.draw(prompt, ed.promptRect, blink==0 and focus==prompt)
    ed.theme.drawBorder(ed.promptRect, focus==prompt)

    let statusBar = ed.theme.renderText(ed.statusMsg & "     " & main.filename,
                        ed.uiFont,
      if ed.statusMsg == readyMsg: ed.theme.fg else: color(0xff, 0x44, 0x44, 0))
    let bottom = ed.screenH - ed.theme.editorFontSize.cint - ed.theme.uiYGap*2

    let position = ed.theme.renderText("Ln: " & $(getLine(main)+1) &
                                       " Col: " & $(getColumn(main)+1) &
                                       " \\t: " & $main.tabSize &
                                       " " & main.lineending.displayNL,
                                       ed.uiFont, ed.theme.fg)
    renderer.draw(statusBar, 15, bottom)
    renderer.draw(position,
      ed.mainRect.x + ed.mainRect.w - 14*ed.theme.uiFontSize.int, bottom)

    present(renderer)
  freeFonts fontM
  destroy ed

if sdl2.init(INIT_VIDEO) != SdlSuccess:
  echo "SDL_Init"
elif ttfInit() != SdlSuccess:
  echo "TTF_Init"
else:
  startTextInput()
  mainProc(Editor())
sdl2.quit()
