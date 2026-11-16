-- Lasso integration tests against real main.lua and lib/pencillasso.lua.
package.path = package.path .. ";pencil.koplugin/?.lua"
local loaders = package.loaders or package.searchers
local function make_stub() return setmetatable({}, { __index=function() return make_stub() end, __call=function() return make_stub() end }) end
local clock=0
local events={ refresh_fast={}, dirty={}, scheduled={}, view_paints=0 }
local function fake_bb() return { paintRectRGB32=function() end, paintRect=function() end, paintBorder=function() end, blitFrom=function() end, copy=function() return fake_bb() end, free=function() end } end
local screen={ bb=fake_bb(), night_mode=false, getWidth=function() return 1404 end, getHeight=function() return 1872 end, scaleBySize=function(_,v) return v end, refreshFast=function(_,x,y,w,h) table.insert(events.refresh_fast,{x=x,y=y,w=w,h=h}) end, refreshUI=function() end }
local function widget_class(o) o=o or {}; o.new=function(cls,t) t=setmetatable(t or {},{__index=cls}); if t.init then t:init() end; return t end; o.extend=function(cls,sub) return widget_class(setmetatable(sub or {},{__index=cls})) end; return o end
local stubs={
 ["device"]=setmetatable({screen=screen},{__index=function() return function() return true end end}),
 ["ui/uimanager"]=setmetatable({setDirty=function(_,w) table.insert(events.dirty,w) end,scheduleIn=function(_,_,fn) table.insert(events.scheduled,fn) end},{__index=function() return function() end end}),
 ["ui/time"]={now=function() return clock end,to_ms=function(t) return t end},
 ["ui/geometry"]={new=function(_,t) return t end},
 ["ui/widget/textwidget"]={new=function() return {getSize=function() return {w=40,h=20} end,paintTo=function() end,free=function() end} end},
 ["ui/widget/container/inputcontainer"]=widget_class(), ["gettext"]=function(s) return s end,
 ["logger"]=setmetatable({},{__index=function() return function() end end}),
 ["ffi/util"]={template=function(s) return s end},
}
local function load_pencil()
 table.insert(loaders,2,function(name)
                  if name == "pencilinput" then return function() return dofile("pencil.koplugin/pencilinput.lua") end end
                  if name=="lib/geometry" or name=="lib/penciltool" or name=="lib/pencilstrokes" or name=="lib/pencilnotes" or name=="lib/pencillasso" then return nil end
  return function() return stubs[name] or make_stub() end
 end)
 local Pencil=dofile("pencil.koplugin/main.lua"); table.remove(loaders,2); return Pencil
end
local Pencil=load_pencil()
local PencilTool=require("lib/penciltool")
local PencilNotes=require("lib/pencilnotes")
local PencilLasso=require("lib/pencillasso")
local make_tool=dofile("spec/helpers/make_tool.lua")
local function hline(x0,x1,y) local pts={}; for x=x0,x1,10 do pts[#pts+1]={x=x,y=y} end; return {page=1,tool="pen",width=3,points=pts} end
local function new_pencil()
 local p=setmetatable({tool=make_tool(PencilTool),annotation_groups={},refresh_interval_ms=16,input_debug_mode=false,side_button_down=false,pen_down=false,view={paintTo=function() events.view_paints=events.view_paints+1 end},ui={dialog="ReaderUI"},save_delay_ms=1500},{__index=Pencil})
 p:initStrokeStore(); p.notes_feature=PencilNotes:new{plugin=p}; p.lasso_feature=PencilLasso:new{plugin=p}
 for _,s in ipairs({hline(100,300,100),hline(100,300,500)}) do p.store:add(s) end
 p.isEnabled=function() return true end; p.isOverlayActive=function() return false end; p.transformCoordinates=function(_,x,y) return x,y end; p.getCurrentPage=function() return 1 end; p.paintTo=function() end; p.drawLineSegment=function() end
 p.rebuilds=0; p.rebuildAnnotationGroups=function(self) self.rebuilds=self.rebuilds+1 end; p.saveStrokes=function() end
 return p
end
local function pen(p,x,y) p:handleStylusSlot(nil,{id=1,x=x,y=y,tool=1}) end
local function lift(p) p:handleStylusSlot(nil,{id=-1,tool=1}) end
local function circle_top(p) p.lasso_feature:start(); for _,pt in ipairs({{80,70},{320,70},{320,130},{80,130},{80,72}}) do pen(p,pt[1],pt[2]) end; lift(p) end
describe("lasso object (real main.lua)",function()
 before_each(function() clock=0; events.refresh_fast,events.dirty,events.scheduled,events.view_paints={},{},{},0 end)
 it("selects only strokes inside",function() local p=new_pencil(); circle_top(p); assert.are.equal("selected",p.lasso_feature.state.phase); assert.are.equal(1,#p.lasso_feature.state.strokes); assert.are.equal(100,p.lasso_feature.state.strokes[1].points[1].y) end)
 it("deletes and undo restores",function() local p=new_pencil(); circle_top(p); local _,b=p.lasso_feature:layout(); pen(p,b[1].x+5,b[1].y+5); lift(p); assert.is_false(p.lasso_feature:isActive()); assert.are.equal(1,#p.store.strokes); p:undoLastStroke(); assert.are.equal(2,#p.store.strokes) end)
 it("moves with undo and redo",function() local p=new_pencil(); circle_top(p); pen(p,200,100); clock=200; pen(p,250,160); lift(p); local moved=p.store.strokes[1]; assert.are.same({x=150,y=160},moved.points[1]); p:undoLastStroke(); assert.are.same({x=100,y=100},moved.points[1]); p:redoLastStroke(); assert.are.same({x=150,y=160},moved.points[1]) end)
 it("moves page anchored strokes in page space",function() local p=new_pencil(); local s=p.store.strokes[1]; s.page_points={}; for i,pt in ipairs(s.points) do s.page_points[i]={x=pt.x/2,y=pt.y/2} end; s._vz,s._vox,s._voy=2,0,0; p.ui.paging={}; p.view.page_scroll=false; p.view.state={page=1,zoom=2,offset={x=0,y=0}}; p.view.visible_area={x=0,y=0}; circle_top(p); pen(p,200,100); pen(p,240,140); lift(p); assert.are.same({x=70,y=70},s.page_points[1]); assert.are.same({x=140,y=140},s.points[1]); p:undoLastStroke(); assert.are.same({x=50,y=50},s.page_points[1]) end)
 it("cancels an empty loop and outside tap",function() local p=new_pencil(); p.lasso_feature:start(); for _,pt in ipairs({{600,600},{700,600},{700,700},{600,700}}) do pen(p,pt[1],pt[2]) end; lift(p); assert.is_false(p.lasso_feature:isActive()); circle_top(p); pen(p,900,900); lift(p); assert.is_false(p.lasso_feature:isActive()) end)
 it("runs hold menu actions",function() local p=new_pencil(); local called={}; p.undoLastStroke=function() called[#called+1]="undo" end; p.redoLastStroke=function() called[#called+1]="redo" end; p.notes_feature.openAt=function(_,x,y) called[#called+1]="note "..x..","..y end; p:runHoldMenuAction("undo",1,2); p:runHoldMenuAction("redo",1,2); p:runHoldMenuAction("note",10,20); p:runHoldMenuAction("lasso",1,2); assert.are.same({"undo","redo","note 10,20"},called); assert.are.equal("armed",p.lasso_feature.state.phase) end)
 it("previews drag without repainting page",function() local p=new_pencil(); circle_top(p); local paints=events.view_paints; pen(p,200,100); for i=1,5 do clock=clock+50; pen(p,200+i*10,100+i*10) end; assert.are.equal(paints,events.view_paints); assert.is_true(#events.refresh_fast>=4) end)
 it("repaints after move and defers rebuild",function() local p=new_pencil(); circle_top(p); pen(p,200,100); clock=100; pen(p,250,160); lift(p); assert.are.equal("ReaderUI",events.dirty[#events.dirty]); assert.are.equal(0,p.rebuilds); for _,fn in ipairs(events.scheduled) do fn() end; assert.are.equal(1,p.rebuilds) end)
 it("keeps group indices after delete",function() local p=new_pencil(); p.annotation_groups={{id="a",stroke_indices={1}},{id="b",stroke_indices={2}}}; circle_top(p); local _,b=p.lasso_feature:layout(); pen(p,b[1].x+5,b[1].y+5); lift(p); assert.are.same({},p.annotation_groups[1].stroke_indices); assert.are.same({1},p.annotation_groups[2].stroke_indices) end)
end)
