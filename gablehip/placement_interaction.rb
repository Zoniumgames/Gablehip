require 'sketchup.rb'

module Gablehip
  # Shared pre-placement interaction for all Gablehip templates.
  # It affects only the floating preview; the parametric editing engines are untouched.
  module PlacementInteraction
    CTRL_KEY = 17
    ALT_KEY = 18
    ANCHOR_ORANGE = Sketchup::Color.new(242, 128, 32, 255)
    XRAY_EDGE = Sketchup::Color.new(85, 85, 85, 210)

    def setup_placement_interaction
      @placement_point = nil
      @placement_angle = 0.degrees
      @placement_mode = nil
      @anchor_hover = nil
      @anchor_candidates = placement_anchor_candidates(@inst.definition.entities)
      @anchor = @anchor_candidates[:front_left] || @anchor
      @preview_hidden_for_interaction = false
      @rotation_start_x = nil
    end

    def placement_anchor_candidates(entities)
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
      return {} if pts.empty?

      min_z=pts.map(&:z).min
      bottom=pts.select{|p|(p.z-min_z).abs<=0.05.inch}
      bottom=pts if bottom.empty?
      min_x,max_x=bottom.map(&:x).minmax
      min_y,max_y=bottom.map(&:y).minmax
      nearest=lambda do |tx,ty|
        bottom.min_by{|p|(p.x-tx).abs+(p.y-ty).abs}
      end
      {
        front_left:  nearest.call(min_x,min_y),
        front_right: nearest.call(max_x,min_y),
        back_left:   nearest.call(min_x,max_y),
        back_right:  nearest.call(max_x,max_y)
      }
    end

    def placement_transform(point=@placement_point)
      return Geom::Transformation.new unless point && @anchor
      rotate=Geom::Transformation.rotation(@anchor, Z_AXIS, @placement_angle || 0.degrees)
      move=Geom::Transformation.translation(point-@anchor)
      move * rotate
    end

    def apply_placement_transform
      return unless @inst && @inst.valid? && @placement_point
      @inst.transformation=placement_transform
    end

    def placement_interaction_active?
      !!@placement_mode
    end

    def begin_anchor_select(view)
      return if @placement_mode==:anchor
      end_placement_interaction_visual
      @placement_mode=:anchor
      @anchor_hover=nil
      begin_placement_interaction_visual
      Sketchup.status_text='CTRL Anchor Select · Move over a corner, release CTRL to keep it.'
      view.invalidate
    end

    def begin_rotation(view)
      return if @placement_mode==:rotate
      end_placement_interaction_visual
      @placement_mode=:rotate
      @rotation_start_x=@last_mouse_x
      begin_placement_interaction_visual
      Sketchup.status_text='ALT Rotate Placement · Move right for 90°, left for 0°.'
      view.invalidate
    end

    def end_anchor_select(view)
      return unless @placement_mode==:anchor
      @anchor=@anchor_hover if @anchor_hover
      @anchor_hover=nil
      @placement_mode=nil
      end_placement_interaction_visual
      apply_placement_transform
      Sketchup.status_text='Move mouse, click to place. CTRL anchor · ALT rotate 90° · Esc cancels.'
      view.invalidate
    end

    def end_rotation(view)
      return unless @placement_mode==:rotate
      @placement_mode=nil
      @rotation_start_x=nil
      end_placement_interaction_visual
      apply_placement_transform
      Sketchup.status_text='Move mouse, click to place. CTRL anchor · ALT rotate 90° · Esc cancels.'
      view.invalidate
    end

    def begin_placement_interaction_visual
      return unless @inst && @inst.valid?
      @preview_hidden_for_interaction=!@inst.hidden?
      @inst.hidden=true if @preview_hidden_for_interaction
    end

    def end_placement_interaction_visual
      return unless @inst && @inst.valid?
      if @preview_hidden_for_interaction
        @inst.hidden=false
      end
      @preview_hidden_for_interaction=false
    end

    def update_anchor_hover(view,x,y)
      return unless @placement_mode==:anchor
      best=nil
      best_dist=Float::INFINITY
      @anchor_candidates.each_value do |local|
        world=local.transform(@inst.transformation)
        s=view.screen_coords(world)
        d=Math.sqrt((s.x-x)**2+(s.y-y)**2)
        if d<best_dist
          best_dist=d
          best=local
        end
      end
      # Enter at 18 px; once snapped, keep it until the cursor leaves 28 px.
      limit=@anchor_hover ? 28.0 : 18.0
      @anchor_hover=(best_dist<=limit ? best : nil)
    end

    def update_rotation_from_mouse(x)
      return unless @placement_mode==:rotate && @rotation_start_x
      dx=x-@rotation_start_x
      new_angle =
        if dx>=18
          90.degrees
        elsif dx<=-18
          0.degrees
        else
          @placement_angle
        end
      return if new_angle==@placement_angle
      @placement_angle=new_angle
      apply_placement_transform
    end

    def placement_on_mouse_move(view,x,y)
      @last_mouse_x=x
      @last_mouse_y=y
      if @placement_mode==:anchor
        update_anchor_hover(view,x,y)
        view.invalidate
        return true
      elsif @placement_mode==:rotate
        update_rotation_from_mouse(x)
        view.invalidate
        return true
      end
      false
    end

    def placement_on_key_down(key,view)
      if key==CTRL_KEY
        begin_anchor_select(view)
        true
      elsif key==ALT_KEY
        begin_rotation(view)
        true
      else
        false
      end
    end

    def placement_on_key_up(key,view)
      if key==CTRL_KEY && @placement_mode==:anchor
        end_anchor_select(view)
        true
      elsif (key==ALT_KEY) && @placement_mode==:rotate
        end_rotation(view)
        true
      else
        false
      end
    end

    def placement_cancel_interaction
      @placement_mode=nil
      @anchor_hover=nil
      @rotation_start_x=nil
      end_placement_interaction_visual
    end

    def draw_placement_interaction(view)
      draw_placement_xray(view) if placement_interaction_active?
      draw_anchor_points(view) if @placement_mode==:anchor
      draw_placement_help(view)
    rescue => e
      puts "Gablehip placement draw error: #{e.message}"
    end

    def draw_placement_xray(view)
      return unless @inst && @inst.valid?

      screen_segments=[]
      walker=lambda do |ents,tr,depth|
        return if depth>35
        ents.each do |e|
          next unless e.valid?
          case e
          when Sketchup::Edge
            a=e.start.position.transform(tr)
            b=e.end.position.transform(tr)
            sa=view.screen_coords(a)
            sb=view.screen_coords(b)
            screen_segments << Geom::Point3d.new(sa.x,sa.y,0)
            screen_segments << Geom::Point3d.new(sb.x,sb.y,0)
          when Sketchup::Group
            walker.call(e.entities,tr*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,tr*e.transformation,depth+1)
          end
        end
      end

      walker.call(@inst.definition.entities,@inst.transformation,0)
      return if screen_segments.empty?

      # Screen-space ghost: always visible and independent of SketchUp's
      # model depth buffer, eliminating partial/disappearing X-Ray edges.
      view.drawing_color=XRAY_EDGE
      view.line_width=2
      view.draw2d(GL_LINES,screen_segments)
      view.line_width=1
    end

    def draw_anchor_points(view)
      @anchor_candidates.each_value do |local|
        world=local.transform(@inst.transformation)
        hovered=@anchor_hover && local.distance(@anchor_hover)<0.001.inch
        selected=@anchor && local.distance(@anchor)<0.001.inch
        size=hovered ? 18 : (selected ? 14 : 10)
        style=hovered ? 3 : 2
        view.draw_points([world],size,style,ANCHOR_ORANGE)
      end
      if @anchor_hover
        s=view.screen_coords(@anchor_hover.transform(@inst.transformation))
        view.draw_text([s.x+12,s.y-22],'ANCHOR SNAP',:color=>ANCHOR_ORANGE,:size=>10,:bold=>true)
      end
    end

    def draw_placement_help(view)
      lines=[
        ['Hold CTRL','Select placement anchor',:anchor],
        ['Hold ALT','Rotate placement 90°',:rotate]
      ]
      active=(@placement_mode==:anchor ? :anchor : (@placement_mode==:rotate ? :rotate : nil))
      x=18; y=18; line_h=19; pad_x=10; pad_y=8; width=285
      height=(lines.length*line_h)+(pad_y*2)
      bg=Sketchup::Color.new(245,245,245,220)
      border=Sketchup::Color.new(150,150,150,180)
      normal=Sketchup::Color.new(45,45,45,255)
      blue=Sketchup::Color.new(0,122,204,255)
      rect=[Geom::Point3d.new(x,y,0),Geom::Point3d.new(x+width,y,0),Geom::Point3d.new(x+width,y+height,0),Geom::Point3d.new(x,y+height,0)]
      view.drawing_color=bg; view.draw2d(GL_QUADS,rect)
      view.drawing_color=border; view.line_width=1; view.draw2d(GL_LINE_LOOP,rect)
      lines.each_with_index do |(label,desc,key),i|
        is_active=(key==active)
        color=is_active ? (key==:anchor ? ANCHOR_ORANGE : blue) : normal
        prefix=is_active ? '> ' : '  '
        view.draw_text([x+pad_x,y+pad_y+i*line_h],"#{prefix}#{label}  -  #{desc}",:color=>color,:size=>10,:bold=>is_active)
      end
    end
  end
end
