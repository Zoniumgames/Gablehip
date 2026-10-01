require 'sketchup.rb'
require_relative 'placement_interaction'
module Gablehip
  class PlacementTool
    include PlacementInteraction
    def initialize(path,mode=1)
      @path=path
      @mode=mode.to_i
      @ip=Sketchup::InputPoint.new
      @inst=nil
      @open=false
      @placed=false
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
      m.start_operation('Place Gablehip',true)
      @open=true

      d=m.definitions.load(@path)
      @anchor=real_pg_anchor_local(d.entities) || d.bounds.corner(0)

      @inst=m.active_entities.add_instance(d,Geom::Transformation.new)
      @inst.make_unique
      @inst.name='Gablehip'
      @inst.set_attribute(Gablehip::ATTR_DICT,'template','gable_roof')
      @inst.set_attribute(Gablehip::ATTR_DICT,'version','2.3.0')
      @inst.set_attribute(Gablehip::ATTR_DICT,'mode',@mode)

      build_mode2_preview_returns if @mode==2

      setup_placement_interaction

      Sketchup.status_text='Move mouse, click to place. CTRL anchor · ALT rotate 90° · Esc cancels.'
    rescue => e
      m.abort_operation if @open
      @open=false
      UI.messagebox("Placement error:\n#{e.message}")
      m.select_tool(nil)
    end

    def preview_role_face(role)
      result=nil
      walker=lambda do |ents,depth|
        return if depth>30 || result
        ents.each do |e|
          case e
          when Sketchup::Face
            if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
              result=e
              break
            end
          when Sketchup::Group
            walker.call(e.entities,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,depth+1)
          end
          break if result
        end
      end
      walker.call(@inst.definition.entities,0) if @inst && @inst.valid?
      result
    end

    def preview_ridge_x
      result=nil
      walker=lambda do |ents,depth|
        return if depth>30 || result
        ents.each do |e|
          case e
          when Sketchup::Edge
            if e.get_attribute(Gablehip::ATTR_DICT,'role')=='ridge'
              result=(e.start.position.x+e.end.position.x)*0.5
              break
            end
          when Sketchup::Group
            walker.call(e.entities,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,depth+1)
          end
          break if result
        end
      end
      walker.call(@inst.definition.entities,0)
      result
    end

    def preview_return_triangle(end_name,side)
      wall_side=preview_role_face(side==:left ? 'wall_left' : 'wall_right')
      fascia=preview_role_face(end_name==:front ? 'fascia_front' : 'fascia_back')
      wall_end=preview_role_face(end_name==:front ? 'wall_front' : 'wall_back')
      cx=preview_ridge_x
      return nil unless wall_side && fascia && wall_end && cx

      wall_x=wall_side.bounds.center.x
      candidates=[]
      fascia.edges.each do |e|
        a=e.start.position
        b=e.end.position
        mx=(a.x+b.x)*0.5
        next if side==:left && mx>cx+0.05.inch
        next if side==:right && mx<cx-0.05.inch
        dx=(b.x-a.x).abs
        dz=(b.z-a.z).abs
        next if dx<1.0.inch
        len=Math.sqrt(dx*dx+dz*dz)
        candidates << [e,len,(a.z+b.z)*0.5]
      end
      return nil if candidates.empty?

      max_len=candidates.map{|x|x[1]}.max
      long=candidates.select{|x|x[1]>=max_len*0.70}
      edge=(long.min_by{|x|x[2]} || candidates.min_by{|x|x[2]})[0]

      a0=edge.start.position
      b0=edge.end.position
      dx=b0.x-a0.x
      return nil if dx.abs<1.0e-9
      t=(wall_x-a0.x)/dx
      return nil if t < -0.05 || t > 1.05
      hit_z=a0.z+(b0.z-a0.z)*t
      outer=side==:left ? (a0.x<b0.x ? a0 : b0) : (a0.x>b0.x ? a0 : b0)

      y=wall_end.bounds.center.y
      [
        Geom::Point3d.new(wall_x,y,outer.z),
        Geom::Point3d.new(outer.x,y,outer.z),
        Geom::Point3d.new(wall_x,y,hit_z)
      ]
    end

    def preview_return_role(end_name,side)
      "return_#{end_name}_#{side}"
    end

    def preview_exact_tagged_return(role)
      found=nil
      walker=lambda do |ents,tr,depth|
        return if depth>30 || found
        ents.each do |e|
          case e
          when Sketchup::Face
            if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
              found=[e,tr]
              break
            end
          when Sketchup::Group
            walker.call(e.entities,tr*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,tr*e.transformation,depth+1)
          end
          break if found
        end
      end
      walker.call(@inst.definition.entities,Geom::Transformation.new,0)
      found
    end

    def preview_ordered_tagged_triangle(face,tr)
      pts=face.outer_loop.vertices.map{|v|v.position.transform(tr)}
      return nil unless pts.length==3
      pairs=[[0,1],[0,2],[1,2]]
      pair=pairs.min_by{|i,j|(pts[i].x-pts[j].x).abs}
      i,j=pair
      k=([0,1,2]-pair).first
      p1=pts[i]; p2=pts[j]
      a,c=p1.z<=p2.z ? [p1,p2] : [p2,p1]
      [a,pts[k],c]
    end

    def preview_exact_return_triangle(end_name,side)
      raw=preview_return_triangle(end_name,side)
      return nil unless raw
      role=preview_return_role(end_name,side)
      found=preview_exact_tagged_return(role)
      return raw unless found
      exact=preview_ordered_tagged_triangle(found[0],found[1])
      return raw unless exact && exact.length==3
      exact
    rescue => e
      puts "Mode 2 preview exact Return error: #{e.message}"
      raw
    end

    def clean_preview_return_visual(group,wall,triangle_pts)
      return unless group && group.valid? && wall && triangle_pts
      tol=0.02.inch
      wall_y=wall.bounds.center.y

      # Hide only the wall-plane triangular seam. Preserve outward silhouette.
      group.entities.grep(Sketchup::Edge).each do |edge|
        a=edge.start.position
        b=edge.end.position
        if (a.y-wall_y).abs<=tol && (b.y-wall_y).abs<=tol
          edge.hidden=true
          edge.soft=true if edge.respond_to?(:soft=)
          edge.smooth=true if edge.respond_to?(:smooth=)
        end
      end
    rescue => e
      puts "Mode 2 preview seam cleanup error: #{e.message}"
    end

    def build_mode2_preview_returns
      return unless @mode==2 && @inst && @inst.valid?

      # IMPORTANT: preview must use the exact same Mode 2 engine as the placed
      # object. Do not maintain a second approximation of Return geometry.
      tool=Gablehip::Mode2DragTool.new(@inst)

      # The live tool's calibration/rebuild methods are private by design, but
      # Ruby's send lets PlacementTool invoke that same proven engine here.
      tool.send(:ensure_floor_role)
      tool.send(:load_saved_return_calibration)
      offsets=tool.instance_variable_get(:@return_exact_offsets)
      if !offsets || offsets.empty?
        tool.send(:calibrate_exact_return_positions)
        tool.send(:save_return_calibration)
      end
      tool.send(:rebuild_live_return_solids)
      tool.send(:restore_all_return_edges_visible)

      # Apply the exact same visual cleanup to the preview-generated prisms.
      groups=tool.send(:generated_return_groups)
    rescue => e
      puts "Mode 2 exact preview engine error: #{e.message}"
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

      m=Sketchup.active_model
      m.commit_operation if @open
      @open=false

      SelectionObserver.suspend do
        m.selection.clear
        m.selection.add(@inst)
      end
      tool =
        case @mode
        when 2 then Mode2DragTool.new(@inst)
        when 3 then Mode3DragTool.new(@inst)
        else SemanticDragTool.new(@inst)
        end
      m.select_tool(tool)
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
      Sketchup.active_model.abort_operation if @open
      @open=false
      Sketchup.active_model.select_tool(nil)
      v.invalidate
    end
  end
end
