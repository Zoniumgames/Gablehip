require 'sketchup.rb'
require_relative 'placement_interaction'
module Gablehip
  class HipPlacementTool
    include PlacementInteraction
    def initialize(path)
      @path=path; @ip=Sketchup::InputPoint.new; @inst=nil; @open=false; @placed=false
    end

    # Returns a REAL lower house corner from semantic wall/floor geometry,
    # instead of a corner of SketchUp's selection bounding box.
    def real_pg_anchor_local(entities)
      pts=[]
      walker=lambda do |ents,tr,depth|
        return if depth>40
        ents.each do |e|
          next unless e.valid?
          case e
          when Sketchup::Face
            role=e.get_attribute(Gablehip::ATTR_DICT,'role').to_s
            if role=='floor' || role.start_with?('wall_')
              e.vertices.each{|vv| pts << vv.position.transform(tr)}
            end
          when Sketchup::Group
            walker.call(e.entities,tr*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,tr*e.transformation,depth+1)
          end
        end
      end
      walker.call(entities,Geom::Transformation.new,0)
      return nil if pts.empty?

      min_z=pts.map(&:z).min
      ztol=0.05.inch
      bottom=pts.select{|p|(p.z-min_z).abs<=ztol}
      bottom=pts if bottom.empty?

      # Deterministic physical corner: minimum X / minimum Y on the wall base.
      min_x=bottom.map(&:x).min
      min_y=bottom.map(&:y).min
      bottom.min_by{|p|(p.x-min_x).abs+(p.y-min_y).abs}
    end

    def activate
      m=Sketchup.active_model
      m.start_operation('Place Parametric Hip',true); @open=true
      d=m.definitions.load(@path); @anchor=real_pg_anchor_local(d.entities) || d.bounds.corner(0)
      @inst=m.active_entities.add_instance(d,Geom::Transformation.new); @inst.make_unique
      @inst.name='Parametric Hip'
      @inst.set_attribute(Gablehip::ATTR_DICT,'template','hip_roof')
      @inst.set_attribute(Gablehip::ATTR_DICT,'version','2.3.0')
      @inst.set_attribute(Gablehip::ATTR_DICT,'family','hip')
      setup_placement_interaction

      Sketchup.status_text='Move mouse, click to place. CTRL anchor · ALT rotate 90° · Esc cancels.'
    rescue => e
      m.abort_operation if @open; @open=false
      UI.messagebox("Hip placement error:\n#{e.message}"); m.select_tool(nil)
    end

    # v2.3.0: the floating preview must never participate in its own pick.
    # Otherwise InputPoint can infer against the PG being positioned, creating
    # a feedback loop that can pull the preview toward the camera / fill view.
    def pick_without_preview(view,x,y)
      return false unless @inst && @inst.valid?
      was_hidden=@inst.hidden?
      begin
        @inst.hidden=true
        @ip.clear if @ip.respond_to?(:clear)
        @ip.pick(view,x,y)
      ensure
        @inst.hidden=was_hidden if @inst && @inst.valid?
      end
      @ip.valid?
    end

    def onMouseMove(_,x,y,v)
      return unless @inst && @inst.valid?
      return if placement_on_mouse_move(v,x,y)
      return unless pick_without_preview(v,x,y)
      @placement_point=@ip.position
      apply_placement_transform
      v.invalidate
    end
    def onLButtonDown(_,x,y,v)
      return unless @inst && @inst.valid?
      return if placement_interaction_active?
      return unless pick_without_preview(v,x,y)
      @placement_point=@ip.position
      apply_placement_transform
      @placed=true
      m=Sketchup.active_model; m.commit_operation if @open; @open=false
      SelectionObserver.suspend { m.selection.clear; m.selection.add(@inst) }
      m.select_tool(HipDragTool.new(@inst))
    end
    def onKeyDown(key,repeat,flags,v)
      placement_on_key_down(key,v)
    end

    def onKeyUp(key,repeat,flags,v)
      placement_on_key_up(key,v)
    end

    def draw(v)
      draw_placement_interaction(v)
    end

    def deactivate(v)
      placement_cancel_interaction
      v.invalidate if v
    rescue
    end

    def onCancel(_,v)
      placement_cancel_interaction
      @inst.erase! if @inst && @inst.valid? && !@placed
      Sketchup.active_model.abort_operation if @open; @open=false
      Sketchup.active_model.select_tool(nil); v.invalidate
    end
  end
end
