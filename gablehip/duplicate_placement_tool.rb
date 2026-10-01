require 'sketchup.rb'

module Gablehip
  class DuplicatePlacementTool
    def initialize(source)
      @source=source
      @ip=Sketchup::InputPoint.new
      @inst=nil
      @open=false
      @placed=false
    end


    # v3.0.1: preserve complete instance-level parametric state.
    def copy_instance_attributes(source,target)
      source.attribute_dictionaries&.each do |dict|
        dict.each_pair { |key,value| target.set_attribute(dict.name,key,value) }
      end
    end

    # Root make_unique is not enough for these templates: nested component
    # instances can still point to definitions shared with the source Gable.
    # The parametric tools recurse into those definitions, so they must also
    # be detached. Groups are traversed, but only ComponentInstances need
    # explicit make_unique.
    def deep_make_unique(entities,depth=0)
      return if depth>40
      entities.to_a.each do |e|
        next unless e.valid?
        case e
        when Sketchup::Group
          deep_make_unique(e.entities,depth+1)
        when Sketchup::ComponentInstance
          e.make_unique if e.definition.instances.length>1
          deep_make_unique(e.definition.entities,depth+1)
        end
      end
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
      unless @source && @source.valid?
        Sketchup.active_model.select_tool(nil)
        return
      end

      m=Sketchup.active_model
      m.start_operation('Duplicate Gablehip',true)
      @open=true

      # First detach the root definition, then recursively detach every nested
      # component definition that the semantic editor can reach.
      @inst=m.active_entities.add_instance(@source.definition,@source.transformation)
      @inst.make_unique
      deep_make_unique(@inst.definition.entities)

      @inst.name=@source.name

      # Exact parametric duplicate: copy every root attribute dictionary.
      # This preserves Mode 2 Return calibration and Hip template/family state.
      copy_instance_attributes(@source,@inst)

      unless @inst.get_attribute(Gablehip::ATTR_DICT,'version')
        @inst.set_attribute(Gablehip::ATTR_DICT,'version','2.3.0')
      end

      anchor_local=real_pg_anchor_local(@source.definition.entities)
      @anchor_world=anchor_local ? anchor_local.transform(@source.transformation) : @source.bounds.corner(0)
      SelectionObserver.suspend { m.selection.clear }
      Sketchup.status_text='Duplicate Gablehip: exact parametric copy — move mouse, click to place. Esc cancels.'
    rescue => e
      m.abort_operation if @open rescue nil
      @open=false
      UI.messagebox("Parametric duplicate error:\n#{e.message}")
      m.select_tool(nil) rescue nil
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
      return unless pick_without_preview(v,x,y)
      delta=@ip.position-@anchor_world
      @inst.transform!(Geom::Transformation.translation(delta))
      @anchor_world=@anchor_world+delta
      v.invalidate
    end

    def onLButtonDown(_,x,y,v)
      return unless @inst && @inst.valid?
      return unless pick_without_preview(v,x,y)
      delta=@ip.position-@anchor_world
      @inst.transform!(Geom::Transformation.translation(delta))
      @anchor_world=@anchor_world+delta
      @placed=true

      m=Sketchup.active_model
      m.commit_operation if @open
      @open=false
      SelectionObserver.suspend do
        m.selection.clear
        m.selection.add(@inst)
      end
      Gablehip.edit(@inst)
      v.invalidate
    end

    def onCancel(_,v)
      @inst.erase! if @inst && @inst.valid? && !@placed
      Sketchup.active_model.abort_operation if @open
      @open=false
      Sketchup.active_model.select_tool(nil)
      v.invalidate
    end
  end
end
