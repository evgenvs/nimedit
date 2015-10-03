

import buffertype, themes
import sdl2, sdl2/ttf, prims

type
  TabBar* = Buffer

proc rect*(x,y,w,h: int): Rect = sdl2.rect(x.cint, y.cint, w.cint, h.cint)

proc drawBorder*(t: InternalTheme; x, y, w, h: int; b: bool; arc=8) =
  let p = Pixel(col: t.active[b], thickness: 2,
                gradient: color(0xff, 0xff, 0xff, 0))
  t.renderer.roundedRect(x, y, x+w-1, y+h-1, arc, p)
  t.renderer.setDrawColor(t.bg)

proc renderText*(t: InternalTheme;
                message: string; font: FontPtr; color: Color): TexturePtr =
  var surf: SurfacePtr = renderUtf8Shaded(font, message, color, t.bg)
  if surf == nil:
    echo("TTF_RenderText")
    return nil
  var texture: TexturePtr = createTextureFromSurface(t.renderer, surf)
  if texture == nil:
    echo("CreateTexture")
  freeSurface(surf)
  return texture

proc draw*(renderer: RendererPtr; image: TexturePtr; x, y: int) =
  var
    iW: cint
    iH: cint
  queryTexture(image, nil, nil, addr(iW), addr(iH))
  let r = rect(x.cint, y.cint, iW, iH)
  copy(renderer, image, nil, unsafeAddr r)
  destroy image


proc drawBorder*(t: InternalTheme; rect: Rect; active: bool; arc=8) =
  let yGap = t.uiYGap
  let xGap = t.uiXGap
  t.drawBorder(rect.x - xGap, rect.y - yGap, rect.w + xGap, rect.h + yGap,
               active, arc)

proc drawTextWithBorder*(t: InternalTheme; text: string; active: bool;
                         x, y, screenW: cint): Rect =
  let image = renderText(t, text, t.uiFontPtr, t.fg)
  var
    iW: cint
    iH: cint
  queryTexture(image, nil, nil, addr(iW), addr(iH))
  if iW+x < screenW:
    result = rect(x, y, iW, iH)
    copy(t.renderer, image, nil, addr result)
    destroy image
    result.x += 3
    result.y += 3
    result.w += 3
    result.h += 2
    drawBorder(t, result, active, 4)

proc drawTabBar*(tabs: var TabBar; t: InternalTheme;
                 screenW: cint; e: var Event;
                 active: Buffer): Buffer =
  var it = tabs
  var activeDrawn = false
  var xx = 15.cint
  let yy = t.uiYGap.cint
  while true:
    let header = it.heading & (if it.changed: "*" else: "")
    let rect = drawTextWithBorder(t, header,
                                  it == active, xx, yy, screenW)
    # if there was no room left to draw this tab:
    if rect.w == 0:
      if not activeDrawn:
        # retry the whole rendering, setting the start of the tabbar to
        # something else:
        if it.prev != tabs:
          tabs = it.prev
          return drawTabBar(tabs, t, screenW, e, active)
      break

    activeDrawn = activeDrawn or it == active
    if e.kind == MouseButtonDown:
      let w = e.button
      if w.clicks.int >= 1:
        let p = point(w.x, w.y)
        if rect.contains(p):
          result = it
    inc xx, rect.w + t.uiYGap*2
    it = it.next
    if it == tabs: break