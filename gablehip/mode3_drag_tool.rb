require 'sketchup.rb'

module Gablehip
  class Mode3DragTool
    HOVER_BLUE=Sketchup::Color.new(0,122,204,105)
    HOVER_BLUE_EDGE=Sketchup::Color.new(0,122,204)
    ASYM_YELLOW=Sketchup::Color.new(255,196,0,115)
    ASYM_YELLOW_EDGE=Sketchup::Color.new(255,196,0)
    SNAP_GREEN=Sketchup::Color.new(35,190,85,115)
    SNAP_GREEN_EDGE=Sketchup::Color.new(35,190,85)

    GROUPS={
      'roof'=>['roof'],
      'floor'=>['floor'],
      'soffit'=>[
        'soffit_left','soffit_right'
      ],
      'fascia_front'=>['fascia_front'],
      'fascia_back'=>['fascia_back'],
      'fascia_left'=>['fascia_left'],
      'fascia_right'=>['fascia_right'],
      'wall_front'=>['wall_front'],
      'wall_back'=>['wall_back'],
      'wall_left'=>['wall_left'],
      'wall_right'=>['wall_right'],
      'ridge'=>['ridge'],
      'pitch_left'=>['pitch_left'],
      'pitch_right'=>['pitch_right']
    }.freeze

    WALL_ROLES=%w[wall_front wall_back wall_left wall_right].freeze
    FLOOR_ROLE='floor'.freeze
    RIDGE_ROLE='ridge'.freeze
    PITCH_ROLES=%w[pitch_left pitch_right].freeze
    FASCIA_ROLES=%w[fascia_front fascia_back fascia_left fascia_right].freeze
    SOFFIT_ROLES=%w[soffit_left soffit_right].freeze
    OPPOSITE_WALL={
      'wall_front'=>'wall_back',
      'wall_back'=>'wall_front',
      'wall_left'=>'wall_right',
      'wall_right'=>'wall_left'
    }.freeze

    def initialize(root)
      @root=root
      @hover_role=nil
      @draw_items=[]
      @dragging=false
      @drag_context=nil
      @op_open=false
      @snap_point_world=nil
      @snap_label=nil
      @snap_target_role=nil
      @snap_target_face=nil
      @snap_target_tr=nil
      @alt_wireframe=false
      @alt_root_was_hidden=false
      @shift_visual=false
    end

    def activate
      SelectionObserver.suspend do
        m=Sketchup.active_model
        m.selection.clear
        m.selection.add(@root)
      end
      ensure_floor_role
      Sketchup.status_text='MODE 3: walls, roof, ridge, pitch, fascias and the 2 inclined soffits are editable. SHIFT = asymmetric/individual mode.'
      Sketchup.active_model.active_view.invalidate
    end

    def onMouseMove(flags,x,y,v)
      shift_now=((flags & CONSTRAIN_MODIFIER_MASK) != 0)
      if shift_now != @shift_visual
        @shift_visual=shift_now
        rebuild_draw_items unless @dragging
      end
      if @dragging
        update_drag(x,y,v)
      else
        role=(@alt_wireframe ? pick_role_alt(v,x,y) : pick_role(v,x,y))
        if role != @hover_role
          @hover_role=role
          rebuild_draw_items
        end
        v.tooltip=role ? "Control: #{logical_name(role)}" : 'Gablehip'
      end
      v.invalidate
    end

    def onLButtonDown(flags,x,y,v)
      role=(@alt_wireframe ? pick_role_alt(v,x,y) : pick_role(v,x,y))

      unless role
        SelectionObserver.suspend { Sketchup.active_model.selection.clear }
        Sketchup.active_model.select_tool(nil)
        return
      end

      drag_anchor_world=nil
      begin
        ip=Sketchup::InputPoint.new
        ip.pick(v,x,y)
        drag_anchor_world=ip.position.clone if ip.valid?
      rescue
        drag_anchor_world=nil
      end
      clear_snap_state

      if role=='roof'
        start_roof_drag(x,y,v)
      elsif role==FLOOR_ROLE
        start_floor_drag(x,y,v)
      elsif WALL_ROLES.include?(role)
        start_wall_drag(role,x,y,v,flags)
      elsif role==RIDGE_ROLE
        start_ridge_drag(role,x,y,v)
      elsif PITCH_ROLES.include?(role)
        start_pitch_drag(role,x,y,v,flags)
      elsif FASCIA_ROLES.include?(role)
        start_fascia_drag(role,x,y,v,flags)
      elsif SOFFIT_ROLES.include?(role)
        start_soffit_drag(role,x,y,v)
      else
        UI.beep
        Sketchup.status_text='That control is tagged, but its drag behavior is not implemented yet.'
        return
      end

      @drag_context[:snap_anchor_world]=drag_anchor_world || @drag_context[:origin_world] if @dragging && @drag_context
      v.invalidate
    end

    def onLButtonUp(_,x,y,v)
      return unless @dragging
      update_drag(x,y,v)
      finish_drag
      v.invalidate
    end

    def onCancel(_,v)
      if @dragging
        cancel_drag
      else
        SelectionObserver.suspend { Sketchup.active_model.selection.clear }
        Sketchup.active_model.select_tool(nil)
      end
      v.invalidate
    end

    def onKeyDown(key,repeat,flags,v)
      return unless key==18
      return if @alt_wireframe
      @alt_wireframe=true
      @alt_root_was_hidden=@root.hidden?
      @root.hidden=true unless @alt_root_was_hidden
      @hover_role=nil
      @draw_items=[]
      Sketchup.status_text='ALT Wireframe: rear controls are directly selectable.'
      v.invalidate
    rescue => e
      puts "ALT Wireframe key down error: #{e.message}"
    end

    def onKeyUp(key,repeat,flags,v)
      return unless key==18
      exit_alt_wireframe
      Sketchup.status_text='Gablehip editing active.'
      v.invalidate
    end

    def deactivate(v)
      exit_alt_wireframe
      v.invalidate if v
    rescue
    end

    def draw(v)
      draw_alt_wireframe(v) if @alt_wireframe
      @draw_items.each do |e,tr|
        if e.is_a?(Sketchup::Face)
          # GL_POLYGON is only reliable for convex polygons. Some front/back
          # walls and fascias are concave, so drawing their outer loop as one
          # polygon creates phantom pink triangles. Draw SketchUp's own face
          # tessellation instead; this fills only triangles that truly belong
          # to the face while preserving the existing semantic hover grouping.
          mesh=e.mesh(0)
          v.drawing_color=hover_fill_color
          mesh.polygons.each do |poly|
            pts=poly.map{|idx| mesh.point_at(idx.abs).transform(tr)}
            v.draw(GL_POLYGON,pts) if pts.length >= 3
          end
          v.drawing_color=hover_edge_color
          v.line_width=3
          e.loops.each do |loop|
            pts=loop.vertices.map{|p|p.position.transform(tr)}
            v.draw(GL_LINE_LOOP,pts) if pts.length >= 2
          end
          v.line_width=1
        elsif e.is_a?(Sketchup::Edge)
          a=e.start.position.transform(tr)
          b=e.end.position.transform(tr)
          v.drawing_color=hover_edge_color
          v.line_width=7
          v.draw(GL_LINES,[a,b])
          v.line_width=1
        end
      end

      if @snap_target_face && @snap_target_face.valid?
        begin
          mesh=@snap_target_face.mesh(7)
          pts=[]
          1.upto(mesh.count_polygons) do |pi|
            poly=mesh.polygon_points_at(pi)
            next unless poly && poly.length>=3
            a=poly[0].transform(@snap_target_tr)
            (1...(poly.length-1)).each do |j|
              pts << a << poly[j].transform(@snap_target_tr) << poly[j+1].transform(@snap_target_tr)
            end
          end
          v.drawing_color=SNAP_GREEN
          v.draw(GL_TRIANGLES,pts) unless pts.empty?
        rescue => e
          puts "Parametric target snap draw error: #{e.message}"
        end
      end

      if @snap_point_world
        c=SNAP_GREEN_EDGE
        v.draw_points([@snap_point_world],18,3,c)
        if @drag_context && @drag_context[:snap_anchor_world]
          v.drawing_color=c
          v.line_width=2
          v.draw(GL_LINES,[@drag_context[:snap_anchor_world],@snap_point_world])
          v.line_width=1
        end
        begin
          s=v.screen_coords(@snap_point_world)
          v.draw_text([s.x+12,s.y-18],@snap_label || 'SNAP')
        rescue
        end
      end
      draw_alt_hover(v) if @alt_wireframe && @hover_role
      draw_viewport_help(v)
    rescue => e
      puts "Gablehip draw error: #{e.message}"
    end

    def draw_viewport_help(v)
      return unless @root && @root.valid?

      lines=[
        ['Drag a control',   'Edit template',         :edit],
        ['Hold SHIFT',       'Asymmetric control',    :shift],
        ['Hold ALT',         'X-Ray view',            :alt],
        ['Right-click',      'Duplicate exact copy',  :duplicate],
        ['Drag to geometry', 'Snap',                  :snap]
      ]

      dragging=!!@drag_context
      shift_on=!!(@shift_down || @shift_held || @shift_pressed ||
                  (@drag_context && @drag_context[:asymmetric]))
      alt_on=!!(@alt_wireframe || @alt_down || @alt_held)

      snap_on=false
      if dragging
        dc=@drag_context
        snap_on=!!(dc[:snap_active] || dc[:snapped] || dc[:snap_point] ||
                   dc[:snap_target] || dc[:external_snap] ||
                   dc[:plane_match_active])
      end
      snap_on ||= !!(@snap_active || @snapped || @snap_point ||
                     @external_snap_active || @plane_match_active)

      active_key =
        if snap_on
          :snap
        elsif shift_on
          :shift
        elsif alt_on
          :alt
        elsif dragging
          :edit
        end

      x=18; y=18; line_h=19; pad_x=10; pad_y=8; width=260
      height=(lines.length*line_h)+(pad_y*2)

      bg=Sketchup::Color.new(245,245,245,220)
      border=Sketchup::Color.new(150,150,150,180)
      normal_text=Sketchup::Color.new(45,45,45,255)
      edit_text=Sketchup::Color.new(0,122,204,255)
      shift_text=Sketchup::Color.new(210,155,0,255)
      snap_text=Sketchup::Color.new(25,155,70,255)
      alt_text=Sketchup::Color.new(0,122,204,255)

      rect=[
        Geom::Point3d.new(x,y,0),
        Geom::Point3d.new(x+width,y,0),
        Geom::Point3d.new(x+width,y+height,0),
        Geom::Point3d.new(x,y+height,0)
      ]
      v.drawing_color=bg
      v.draw2d(GL_QUADS,rect)
      v.drawing_color=border
      v.line_width=1
      v.draw2d(GL_LINE_LOOP,rect)

      lines.each_with_index do |parts,i|
        label,description,key=parts
        color =
          if key==active_key
            case key
            when :shift then shift_text
            when :snap  then snap_text
            when :alt   then alt_text
            else edit_text
            end
          else
            normal_text
          end
        prefix=(key==active_key ? '> ' : '  ')
        text="#{prefix}#{label}  -  #{description}"
        opts={:color=>color,:size=>10,:bold=>(key==active_key)}
        v.draw_text([x+pad_x,y+pad_y+(i*line_h)],text,opts)
      end
    rescue => e
      puts "Gablehip viewport help draw error: #{e.message}"
    end

    def hover_fill_color
      @shift_visual ? ASYM_YELLOW : HOVER_BLUE
    end

    def hover_edge_color
      @shift_visual ? ASYM_YELLOW_EDGE : HOVER_BLUE_EDGE
    end

    private

    def alt_walk(ents,tr,depth=0,&block)
      return if depth>30
      ents.each do |e|
        case e
        when Sketchup::Face, Sketchup::Edge
          block.call(e,tr)
        when Sketchup::Group
          alt_walk(e.entities,tr*e.transformation,depth+1,&block)
        when Sketchup::ComponentInstance
          alt_walk(e.definition.entities,tr*e.transformation,depth+1,&block)
        end
      end
    end

    def draw_alt_wireframe(v)
      v.drawing_color=Sketchup::Color.new(65,65,65,255)
      v.line_width=1
      alt_walk(@root.definition.entities,@root.transformation) do |e,tr|
        next unless e.is_a?(Sketchup::Edge)
        v.draw(GL_LINES,[e.start.position.transform(tr),e.end.position.transform(tr)])
      end
    rescue => e
      puts "ALT Wireframe draw error: #{e.message}"
    end

    def draw_alt_hover(v)
      wanted=group_roles(@hover_role)
      v.drawing_color=hover_fill_color
      alt_walk(@root.definition.entities,@root.transformation) do |e,tr|
        next unless e.respond_to?(:get_attribute)
        role=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless role && wanted.include?(role)
        if e.is_a?(Sketchup::Face)
          mesh=e.mesh(0)
          mesh.polygons.each do |poly|
            pts=poly.map do |idx|
              q=v.screen_coords(mesh.point_at(idx.abs).transform(tr))
              Geom::Point3d.new(q.x,q.y,0)
            end
            v.draw2d(GL_POLYGON,pts) if pts.length>=3
          end
        elsif e.is_a?(Sketchup::Edge)
          a=v.screen_coords(e.start.position.transform(tr)); b=v.screen_coords(e.end.position.transform(tr))
          v.line_width=5
          v.draw2d(GL_LINES,[Geom::Point3d.new(a.x,a.y,0),Geom::Point3d.new(b.x,b.y,0)])
          v.line_width=1
        end
      end
    rescue => e
      puts "ALT hover draw error: #{e.message}"
    end

    def exit_alt_wireframe
      return unless @alt_wireframe
      @alt_wireframe=false
      @root.hidden=false if @root && @root.valid? && !@alt_root_was_hidden
      @alt_root_was_hidden=false
      @hover_role=nil
      @draw_items=[]
    rescue => e
      puts "ALT Wireframe restore error: #{e.message}"
    end

    def pick_role_alt(v,x,y)
      mouse=[x.to_f,y.to_f]
      candidates=[]
      inside=lambda do |p,a,b,c|
        sign=lambda{|p1,p2,p3|(p1[0]-p3[0])*(p2[1]-p3[1])-(p2[0]-p3[0])*(p1[1]-p3[1])}
        d1=sign.call(p,a,b); d2=sign.call(p,b,c); d3=sign.call(p,c,a); eps=0.5
        !((d1 < -eps || d2 < -eps || d3 < -eps) && (d1 > eps || d2 > eps || d3 > eps))
      end
      segdist=lambda do |p,a,b|
        vx=b[0]-a[0]; vy=b[1]-a[1]; l=vx*vx+vy*vy
        return Math.hypot(p[0]-a[0],p[1]-a[1]) if l<=1e-9
        t=[[((p[0]-a[0])*vx+(p[1]-a[1])*vy)/l,0.0].max,1.0].min
        Math.hypot(p[0]-(a[0]+t*vx),p[1]-(a[1]+t*vy))
      end
      alt_walk(@root.definition.entities,@root.transformation) do |e,tr|
        role=e.get_attribute(Gablehip::ATTR_DICT,'role') rescue nil
        next unless role && !role.empty?
        if e.is_a?(Sketchup::Face)
          hit=false; depths=[]; mesh=e.mesh(0)
          mesh.polygons.each do |poly|
            world=poly.map{|idx|mesh.point_at(idx.abs).transform(tr)}; next if world.length<3
            scr=world.map{|pt|q=v.screen_coords(pt);[q.x.to_f,q.y.to_f]}
            (1...(scr.length-1)).each do |i|
              if inside.call(mouse,scr[0],scr[i],scr[i+1])
                hit=true; depths.concat([world[0],world[i],world[i+1]].map{|pt|v.camera.eye.distance(pt)})
              end
            end
          end
          candidates << [role,depths.sum/depths.length.to_f,2] if hit && !depths.empty?
        elsif e.is_a?(Sketchup::Edge)
          a=e.start.position.transform(tr); b=e.end.position.transform(tr); sa=v.screen_coords(a); sb=v.screen_coords(b)
          if segdist.call(mouse,[sa.x.to_f,sa.y.to_f],[sb.x.to_f,sb.y.to_f])<=9.0
            candidates << [role,(v.camera.eye.distance(a)+v.camera.eye.distance(b))*0.5,3]
          end
        end
      end
      return nil if candidates.empty?
      kind=candidates.map{|c|c[2]}.max; candidates.select!{|c|c[2]==kind}
      candidates.max_by{|c|c[1]}[0]
    rescue => e
      puts "ALT Wireframe pick error: #{e.message}"
      nil
    end

    def logical_name(role)
      return 'floor / house base' if role==FLOOR_ROLE
      return 'roof' if role=='roof'
      return 'inclined soffits (left + right)' if role.start_with?('soffit_')
      role
    end

    def group_roles(role)
      return GROUPS['roof'] if role=='roof'
      return GROUPS['soffit'] if role.start_with?('soffit_')
      return PITCH_ROLES if PITCH_ROLES.include?(role)
      if FASCIA_ROLES.include?(role)
        return %w[fascia_front fascia_back] if %w[fascia_front fascia_back].include?(role)
        return %w[fascia_left fascia_right]
      end
      GROUPS[role] || [role]
    end

    def pick_role(v,x,y)
      ph=v.pick_helper
      ph.do_pick(x,y)

      ph.count.times do |i|
        path=ph.path_at(i)
        next unless path && path.include?(@root)

        e=path.last
        next unless e.respond_to?(:get_attribute)

        role=e.get_attribute(Gablehip::ATTR_DICT,'role')
        return role if role && !role.empty?
      end
      nil
    end

    def rebuild_draw_items
      @draw_items=[]
      return unless @hover_role

      wanted=group_roles(@hover_role)
      collect_draw(@root.definition.entities,@root.transformation,wanted,0)
    end

    def collect_draw(ents,tr,wanted,depth)
      return if depth>30
      ents.each do |e|
        case e
        when Sketchup::Face, Sketchup::Edge
          role=e.get_attribute(Gablehip::ATTR_DICT,'role')
          @draw_items << [e,tr] if role && wanted.include?(role)
        when Sketchup::Group
          collect_draw(e.entities,tr*e.transformation,wanted,depth+1)
        when Sketchup::ComponentInstance
          collect_draw(e.definition.entities,tr*e.transformation,wanted,depth+1)
        end
      end
    end

    # Find the tagged wall and the exact editing context that owns it.

    # ----------------------------------------------------------------------
    # FLOOR / HOUSE BASE
    # ----------------------------------------------------------------------

    def ensure_floor_role
      return if find_face_context(FLOOR_ROLE)

      candidates=[]
      walker=lambda do |ents,tr,depth|
        return if depth>30
        ents.each do |e|
          case e
          when Sketchup::Face
            pts=e.vertices.map{|v|v.position.transform(tr)}
            next if pts.length<3
            zs=pts.map(&:z)
            next if (zs.max-zs.min).abs > 0.01.inch
            candidates << [e,zs.sum/zs.length.to_f,e.area]
          when Sketchup::Group
            walker.call(e.entities,tr*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,tr*e.transformation,depth+1)
          end
        end
      end

      walker.call(@root.definition.entities,Geom::Transformation.new,0)
      return if candidates.empty?

      lowest_z=candidates.map{|row|row[1]}.min
      same_level=candidates.select{|row|(row[1]-lowest_z).abs<=0.05.inch}
      chosen=same_level.max_by{|row|row[2]}
      chosen[0].set_attribute(Gablehip::ATTR_DICT,'role',FLOOR_ROLE) if chosen
    rescue => e
      puts "Gablehip floor auto-tag error: #{e.message}"
    end

    def start_floor_drag(x,y,v)
      ctx=find_face_context(FLOOR_ROLE)
      unless ctx
        UI.beep
        Sketchup.status_text='Could not find the house floor/base face.'
        return
      end

      face=ctx[:face]
      ents=ctx[:entities]
      local_to_world=ctx[:local_to_world]
      vertices=face.vertices.uniq

      original_positions={}
      vertices.each{|vv| original_positions[vv]=vv.position.clone}

      axis_local=Geom::Vector3d.new(0,0,1)
      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      floor_z=original_positions.values.map(&:z).sum/original_positions.length.to_f

      # v2.5.3 persistent absolute Floor ceiling.
      # IMPORTANT: do not derive the ceiling from wall vertices. After Floor has
      # already been raised once, those wall vertices have changed and a second
      # grab can incorrectly create a new allowance.
      #
      # Instead, derive the ceiling fresh on EVERY grab from the CURRENT
      # structural upper envelope. These semantic roles are present in all
      # Gable modes and Hip, so Hip inherits the exact same protection.
      upper_vertices=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role').to_s
        is_upper=(erole=='roof' ||
                  erole.start_with?('roof_') ||
                  erole.start_with?('soffit_') ||
                  erole.start_with?('fascia_') ||
                  erole.start_with?('pitch_') ||
                  erole=='ridge')
        next unless is_upper

        case e
        when Sketchup::Face
          e.vertices.each{|vv| upper_vertices << vv}
        when Sketchup::Edge
          upper_vertices << e.start << e.end
        end
      end
      upper_vertices.uniq!

      upper_levels=upper_vertices.map{|vv|vv.position.z}
                                .select{|z|z > floor_z+0.001.inch}
      upper_stop=upper_levels.min

      # Preserve the existing tiny clearance. If Floor is already at the stop,
      # max_up becomes zero on the next grab instead of being recalculated from
      # the newly-shortened walls.
      max_up=upper_stop ? [upper_stop-0.01.inch-floor_z,0.0].max : 0.0

      origin_local=face.bounds.center

      @dragging=true
      @hover_role=FLOOR_ROLE
      @drag_context={
        kind: :floor,
        role:FLOOR_ROLE,
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:origin_local.transform(local_to_world),
        local_to_world:local_to_world,
        floor_z:floor_z,
        max_up:max_up,
        start_parameter:nil,
        current_delta_local:0.0
      }

      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)
      Sketchup.active_model.start_operation('Adjust house floor height',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='Floor/base: drag up or down. Roof stays fixed; walls stretch/shrink from the bottom.'
    rescue => e
      cancel_drag
      UI.messagebox("Floor deformation error:
#{e.message}")
    end

    def update_floor_drag(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)

      if ctx[:max_up] && desired_local>ctx[:max_up]
        desired_local=ctx[:max_up]
        Sketchup.status_text='Floor upper limit: minimum wall height reached.'
      end

      moved=[]
      vectors=[]
      ctx[:vertices].each do |vv|
        original=ctx[:original_positions][vv]
        next unless original

        target=original.clone
        target.z=original.z+desired_local
        delta=vv.position.vector_to(target)
        next if delta.length<1.0e-9

        moved << vv
        vectors << delta
      end

      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "Gablehip floor update error: #{e.message}"
    end


    def find_face_context(role)
      result=nil

      walker=lambda do |ents, local_to_root, depth|
        return if depth>30 || result
        ents.each do |e|
          case e
          when Sketchup::Face
            if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
              result={
                face:e,
                entities:ents,
                local_to_root:local_to_root,
                local_to_world:@root.transformation * local_to_root
              }
              break
            end
          when Sketchup::Group
            walker.call(e.entities,local_to_root*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,local_to_root*e.transformation,depth+1)
          end
          break if result
        end
      end

      walker.call(@root.definition.entities,Geom::Transformation.new,0)
      result
    end

    def start_wall_drag(role,x,y,v,flags)
      ctx=find_face_context(role)
      unless ctx
        UI.beep
        Sketchup.status_text="Could not find tagged face #{role}."
        return
      end

      face=ctx[:face]
      ents=ctx[:entities]
      local_to_world=ctx[:local_to_world]

      # Drag axis = outward wall normal.
      axis_local=face.normal.clone
      axis_local.normalize!

      house_center_local=context_bounds_center(ents)
      wall_center_local=face.bounds.center
      center_to_wall=house_center_local.vector_to(wall_center_local)
      axis_local.reverse! if axis_local.dot(center_to_wall) < 0

      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      selected_plane=wall_center_local.vector_to(ORIGIN).reverse.dot(axis_local)

      vertices=[]
      ents.each do |e|
        case e
        when Sketchup::Edge
          vertices << e.start << e.end
        when Sketchup::Face
          e.vertices.each{|vv| vertices << vv}
        end
      end
      vertices.uniq!

      tolerance=0.01.inch

      # Front/back are always a simple length change:
      # opposite end stays fixed; selected end and everything beyond it follows.
      front_back = (role=='wall_front' || role=='wall_back')

      # Left/right default = proportional width deformation.
      # Opposite wall stays fixed, selected wall follows the cursor,
      # and everything between them moves proportionally. That automatically
      # shifts the ridge half as much, keeping the gable symmetric.
      #
      # SHIFT on left/right = asymmetric mode: only selected side follows.
      asymmetric = !front_back && ((flags & CONSTRAIN_MODIFIER_MASK) != 0)

      # Always resolve the opposite wall plane. Besides driving the default
      # left/right proportional deformation, it is also used as a hard safety
      # limit for EVERY wall mode so opposite walls can never cross.
      opposite_plane=nil
      opposite_role=OPPOSITE_WALL[role]
      opposite_ctx=find_face_context(opposite_role)
      if opposite_ctx && opposite_ctx[:entities] == ents
        opposite_plane=opposite_ctx[:face].bounds.center.vector_to(ORIGIN).reverse.dot(axis_local)
      end

      original_span = opposite_plane ? (selected_plane-opposite_plane).abs : nil
      # Keep the wall from reaching the opposite wall. Dynamic guard zone:
      # 2% of the starting span, never less than 6" and never more than 12".
      min_span = if original_span
        [[original_span*0.02, 6.inch].max, 12.inch].min
      else
        nil
      end

      @dragging=true
      @hover_role=role
      original_positions={}
      vertices.each{|vv| original_positions[vv]=vv.position.clone }
      mode3_collect_extra_originals(
        original_positions,
        'soffit_left','soffit_right','fascia_left','fascia_right'
      )

      @drag_context={
        kind: :wall,
        role:role,
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:wall_center_local.transform(local_to_world),
        selected_plane:selected_plane,
        opposite_plane:opposite_plane,
        original_span:original_span,
        min_span:min_span,
        front_back:front_back,
        asymmetric:asymmetric,
        tolerance:tolerance,
        start_parameter:nil,
        current_delta_local:0.0,
        local_to_world:local_to_world
      }

      if asymmetric && opposite_plane
        fascia_vertices=[]
        ents.grep(Sketchup::Face).each do |ff|
          next unless FASCIA_ROLES.include?(entity_role(ff))
          ff.vertices.each { |vv| fascia_vertices << vv unless fascia_vertices.include?(vv) }
        end
        projections=fascia_vertices.map { |vv| vv.position.vector_to(ORIGIN).reverse.dot(axis_local) }
        if projections.length >= 2
          # Smallest non-zero separation in fascia projections approximates
          # the fascia's structural thickness along this resize axis.
          vals=projections.sort
          diffs=vals.each_cons(2).map{|a,b|(b-a).abs}.select{|d| d>0.001.inch}
          fascia_thickness=diffs.min
          if fascia_thickness
            @drag_context[:fascia_safe_span]=[fascia_thickness+0.05.inch,0.1.inch].max
          end
        end
      end

      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation("Resize house from #{role}",true)
      @op_open=true

      rebuild_draw_items

      if front_back
        Sketchup.status_text="Length resize: #{role} follows; opposite end stays fixed."
      elsif asymmetric
        Sketchup.status_text="ASYMMETRIC width mode: only #{role} side follows."
      else
        Sketchup.status_text="MODE 3 width: continuous soffits remain planar; fascia size preserved."
      end
    rescue => e
      cancel_drag
      UI.messagebox("Wall deformation error:
#{e.message}")
    end




    # Soffit drag moves soffit level vertically.
    # Mode 3 moves BOTH continuous inclined soffits together as one level control.
    # SHIFT at drag start moves only the clicked soffit.
    def start_soffit_drag(role,x,y,v)
      selected=find_face_context(role)
      unless selected
        UI.beep
        Sketchup.status_text='Could not find tagged soffit face.'
        return
      end

      ents=selected[:entities]
      local_to_world=selected[:local_to_world]
      asymmetric=false

      soffit_contexts=[]
      SOFFIT_ROLES.each do |r|
        ctx=find_face_context(r)
        soffit_contexts << ctx if ctx && ctx[:entities] == ents
      end

      if soffit_contexts.empty?
        UI.beep
        Sketchup.status_text='No tagged soffit faces found.'
        return
      end

      # Default behavior is the semantic two-soffit group already established by
      # hover. SHIFT keeps the same architecture as walls/pitch/fascia: only
      # the specifically clicked control is edited.
      active_contexts = asymmetric ? [selected] : soffit_contexts

      vertices=[]
      active_contexts.each do |ctx|
        ctx[:face].vertices.each{|vv| vertices << vv}
      end
      vertices.uniq!

      original_positions={}
      vertices.each{|vv| original_positions[vv]=vv.position.clone}

      axis_local=Geom::Vector3d.new(0,0,1)
      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      # Safety references.
      house_base_z=nil
      ents.each do |e|
        next unless e.respond_to?(:bounds)
        z=e.bounds.min.z
        house_base_z=z if house_base_z.nil? || z < house_base_z
      end
      house_base_z ||= 0.0

      # Upper reference comes from the roof/fascia assembly. We do NOT move
      # roof vertices here; this is only a stop that prevents soffits from
      # crossing upward through the eave assembly.
      upper_candidates=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless erole && (erole=='roof' || FASCIA_ROLES.include?(erole) || PITCH_ROLES.include?(erole))
        case e
        when Sketchup::Face
          e.vertices.each{|vv| upper_candidates << vv.position.z}
        when Sketchup::Edge
          upper_candidates << e.start.position.z << e.end.position.z
        end
      end

      highest_active=original_positions.values.map(&:z).max
      lowest_active=original_positions.values.map(&:z).min

      # The closest structural height above the current soffit becomes the
      # upward stop. If no reliable candidate exists, upward motion remains
      # unrestricted rather than inventing a bad limit.
      upper_levels=upper_candidates.select{|z| z > highest_active + 1.0e-6}
      upper_stop=upper_levels.min

      # Keep a tiny topology gap so the soffit never becomes coplanar with the
      # roof/fascia and gets merged/deleted by SketchUp.
      topology_gap=0.1.inch
      max_up = upper_stop ? (upper_stop-topology_gap-highest_active) : nil

      # Downward guard follows the same safe-limit language as pitch/roof:
      # get very close to the floor, but never touch it.
      house_top_z=nil
      ents.each do |e|
        next unless e.respond_to?(:bounds)
        z=e.bounds.max.z
        house_top_z=z if house_top_z.nil? || z > house_top_z
      end
      house_top_z ||= highest_active
      house_height=[house_top_z-house_base_z,1.inch].max
      floor_guard=[[house_height*0.02,6.inch].max,12.inch].min
      min_down=(house_base_z+floor_guard)-lowest_active

      origin_local=selected[:face].bounds.center

      @dragging=true
      @hover_role=role
      @drag_context={
        kind: :soffit,
        role:role,
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:origin_local.transform(local_to_world),
        local_to_world:local_to_world,
        asymmetric:asymmetric,
        max_up:max_up,
        min_down:min_down,
        start_parameter:nil,
        current_delta_local:0.0
      }

      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation(
        asymmetric ? "Adjust #{role} individually" : 'Adjust both inclined soffits vertically',
        true
      )
      @op_open=true
      rebuild_draw_items

      if asymmetric
        Sketchup.status_text="INDIVIDUAL soffit: #{role}. Drag up/down."
      else
        Sketchup.status_text='MODE 3 SOFFITS: left + right move vertically together while preserving slope. SHIFT = clicked side only.'
      end
    rescue => e
      cancel_drag
      UI.messagebox("Soffit deformation error:
#{e.message}")
    end

    def update_soffit_drag(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)

      if ctx[:max_up] && desired_local > ctx[:max_up]
        desired_local=ctx[:max_up]
        Sketchup.status_text='Soffit upper limit: eave/roof assembly reached.'
      elsif desired_local < ctx[:min_down]
        desired_local=ctx[:min_down]
        Sketchup.status_text='Soffit lower limit: safety gap above the house floor reached.'
      end

      moved=[]
      vectors=[]

      # Rigid vertical translation preserves every soffit face perfectly flat
      # and straight. Targets come from drag-start positions, so there is no
      # cumulative skew/drift.
      ctx[:vertices].each do |vv|
        original=ctx[:original_positions][vv]
        next unless original

        target=original.clone
        target.z=original.z+desired_local

        delta=vv.position.vector_to(target)
        next if delta.length < 1.0e-9

        moved << vv
        vectors << delta
      end

      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "Gablehip soffit update error: #{e.message}"
    end

    # Whole-roof drag changes the wall/house height without changing roof shape.
    # Clicking either roof slope moves the ENTIRE roof assembly vertically as
    # one rigid unit: roof faces, ridge, pitches, fascias and all soffits.
    # Shared raw-geometry vertices stretch/shrink the wall faces underneath.
    def start_roof_drag(x,y,v)
      roof_faces_ctx=find_all_face_contexts('roof')
      if roof_faces_ctx.empty?
        UI.beep
        Sketchup.status_text='No tagged roof faces found.'
        return
      end

      first=roof_faces_ctx.first
      ents=first[:entities]
      local_to_world=first[:local_to_world]

      unless roof_faces_ctx.all?{|ctx| ctx[:entities] == ents}
        UI.beep
        Sketchup.status_text='Both roof slopes must belong to the same geometry context.'
        return
      end

      axis_local=Geom::Vector3d.new(0,0,1)
      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      # Every roof-related control belongs to the moving rigid assembly.
      roof_roles=%w[
        roof
        soffit_left soffit_right
        fascia_front fascia_back fascia_left fascia_right
        ridge pitch_left pitch_right
      ]

      vertices=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless erole && roof_roles.include?(erole)

        case e
        when Sketchup::Face
          e.vertices.each{|vv| vertices << vv}
        when Sketchup::Edge
          vertices << e.start << e.end
        end
      end
      vertices.uniq!

      if vertices.empty?
        UI.beep
        Sketchup.status_text='Roof assembly contains no editable vertices.'
        return
      end

      original_positions={}
      vertices.each{|vv| original_positions[vv]=vv.position.clone}

      # The lower stop is based on the CURRENT roof shape. Therefore if the
      # pitches were previously raised/lowered, the whole-roof limit naturally
      # follows that edited geometry.
      lowest_roof_z=original_positions.values.map(&:z).min

      house_base_z=nil
      house_top_z=nil
      ents.each do |e|
        next unless e.respond_to?(:bounds)
        min_z=e.bounds.min.z
        max_z=e.bounds.max.z
        house_base_z=min_z if house_base_z.nil? || min_z < house_base_z
        house_top_z=max_z if house_top_z.nil? || max_z > house_top_z
      end
      house_base_z ||= 0.0
      house_top_z ||= original_positions.values.map(&:z).max

      house_height=[house_top_z-house_base_z,1.inch].max

      # Same philosophy as the wall/pitch limits: the roof may get very close
      # to the floor, but never touch/cross it and destroy wall topology.
      floor_guard=[[house_height*0.02,6.inch].max,12.inch].min
      min_delta=(house_base_z+floor_guard)-lowest_roof_z

      roof_points=roof_faces_ctx.flat_map{|ctx| ctx[:face].vertices.map(&:position)}
      center_local=Geom::Point3d.new(
        roof_points.map(&:x).sum/roof_points.length.to_f,
        roof_points.map(&:y).sum/roof_points.length.to_f,
        roof_points.map(&:z).sum/roof_points.length.to_f
      )

      @dragging=true
      @hover_role='roof'
      @drag_context={
        kind: :roof,
        role:'roof',
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:center_local.transform(local_to_world),
        local_to_world:local_to_world,
        house_base_z:house_base_z,
        floor_guard:floor_guard,
        lowest_roof_z:lowest_roof_z,
        min_delta:min_delta,
        start_parameter:nil,
        current_delta_local:0.0
      }

      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation('Adjust whole roof height',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='WHOLE ROOF: drag up/down to change house height. Roof shape stays unchanged.'
    rescue => e
      cancel_drag
      UI.messagebox("Roof height deformation error:
#{e.message}")
    end

    def find_all_face_contexts(role)
      results=[]

      walker=lambda do |ents, local_to_root, depth|
        return if depth>30
        ents.each do |e|
          case e
          when Sketchup::Face
            if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
              results << {
                face:e,
                entities:ents,
                local_to_root:local_to_root,
                local_to_world:@root.transformation * local_to_root
              }
            end
          when Sketchup::Group
            walker.call(e.entities,local_to_root*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,local_to_root*e.transformation,depth+1)
          end
        end
      end

      walker.call(@root.definition.entities,Geom::Transformation.new,0)
      results
    end

    def update_roof_drag(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)

      # Unlimited upward movement. Downward movement stops just above the floor.
      if desired_local < ctx[:min_delta]
        desired_local=ctx[:min_delta]
        Sketchup.status_text='Whole-roof lower limit: safety gap above the house floor reached.'
      end

      moved=[]
      vectors=[]

      # Rigid vertical translation: every vertex receives the exact same delta.
      # Because targets are based on drag-start positions there is no cumulative
      # deformation/drift when moving up, down, and back again.
      ctx[:vertices].each do |vv|
        original=ctx[:original_positions][vv]
        next unless original

        target=original.clone
        target.z=original.z+desired_local

        delta=vv.position.vector_to(target)
        next if delta.length < 1.0e-9

        moved << vv
        vectors << delta
      end

      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "Gablehip roof height update error: #{e.message}"
    end

    # Ridge drag changes roof height while keeping both eaves fixed.
    # Geometry is always evaluated from the drag-start state so moving the
    # ridge up/down and returning it restores the exact original model.
    def start_ridge_drag(role,x,y,v)
      ridge_ctx=find_edge_context(role)
      unless ridge_ctx
        UI.beep
        Sketchup.status_text='Could not find tagged ridge edge.'
        return
      end

      ents=ridge_ctx[:entities]
      ridge=ridge_ctx[:edge]
      local_to_world=ridge_ctx[:local_to_world]

      # Template-local vertical axis. The component may itself be transformed,
      # therefore mouse tracking uses its transformed world direction.
      axis_local=Geom::Vector3d.new(0,0,1)
      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      ridge_mid=Geom.linear_combination(0.5,ridge.start.position,0.5,ridge.end.position)
      ridge_z=ridge_mid.z

      # The roof faces define the true outer eaves. This is better than using
      # wall planes because it preserves the template's roof overhang.
      roof_faces=find_tagged_entities_in_context(ents,'roof',Sketchup::Face)
      if roof_faces.empty?
        UI.beep
        Sketchup.status_text='No tagged roof faces found in the ridge editing context.'
        return
      end

      roof_vertices=roof_faces.flat_map(&:vertices).uniq
      xs=roof_vertices.map{|vv| vv.position.x}
      left_eave_x=xs.min
      right_eave_x=xs.max
      ridge_x=ridge_mid.x

      # Reject malformed topology early.
      if (ridge_x-left_eave_x).abs < 0.01.inch || (right_eave_x-ridge_x).abs < 0.01.inch
        UI.beep
        Sketchup.status_text='Ridge/eave geometry is invalid for height editing.'
        return
      end

      # Determine the highest fixed eave elevation from roof vertices at the
      # two outer roof boundaries. The ridge can approach it, but never cross.
      eave_tol=0.05.inch
      eave_vertices=roof_vertices.select do |vv|
        (vv.position.x-left_eave_x).abs <= eave_tol ||
        (vv.position.x-right_eave_x).abs <= eave_tol
      end
      eave_z=eave_vertices.map{|vv| vv.position.z}.max
      eave_z ||= roof_vertices.map{|vv| vv.position.z}.min

      original_height=ridge_z-eave_z

      # Only roof-sensitive tagged geometry is deformed. Side eaves/soffits
      # remain fixed; front/back gable/fascia and both roof slopes follow.
      deform_roles=%w[
        roof
        soffit_left soffit_right
        fascia_front fascia_back
        wall_front wall_back
        ridge pitch_left pitch_right
      ]

      vertices=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless erole && deform_roles.include?(erole)

        case e
        when Sketchup::Face
          e.vertices.each{|vv| vertices << vv}
        when Sketchup::Edge
          vertices << e.start << e.end
        end
      end
      vertices.uniq!

      # Ensure every roof boundary vertex participates, even if a role-tagged
      # neighboring face is absent in a custom template.
      vertices.concat(roof_vertices)
      vertices.uniq!

      original_positions={}
      vertices.each{|vv| original_positions[vv]=vv.position.clone }

      # MODE 3: identify the two continuous inclined soffits explicitly.
      # Their inner vertices must follow ridge slope, but unrelated geometry
      # at/below eave height (especially the house floor) must remain frozen.
      ridge_soffit_vertices=[]
      %w[soffit_left soffit_right].each do |srole|
        sctx=find_face_context(srole)
        if sctx && sctx[:entities] == ents
          sctx[:face].vertices.each{|vv| ridge_soffit_vertices << vv}
        end
      end
      ridge_soffit_vertices.uniq!

      @dragging=true
      @hover_role=role
      @drag_context={
        kind: :ridge,
        role:role,
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        ridge_soffit_vertices:ridge_soffit_vertices,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:ridge_mid.transform(local_to_world),
        local_to_world:local_to_world,
        ridge_x:ridge_x,
        ridge_z:ridge_z,
        left_eave_x:left_eave_x,
        right_eave_x:right_eave_x,
        eave_z:eave_z,
        original_height:original_height,
        start_parameter:nil,
        current_delta_local:0.0
      }

      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation('Adjust ridge height',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='MODE 3 ridge: roof + inclined soffits change slope; floor/base remains fixed.'
    rescue => e
      cancel_drag
      UI.messagebox("Ridge deformation error:
#{e.message}")
    end

    def find_edge_context(role)
      result=nil

      walker=lambda do |ents, local_to_root, depth|
        return if depth>30 || result
        ents.each do |e|
          case e
          when Sketchup::Edge
            if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
              result={
                edge:e,
                entities:ents,
                local_to_root:local_to_root,
                local_to_world:@root.transformation * local_to_root
              }
              break
            end
          when Sketchup::Group
            walker.call(e.entities,local_to_root*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,local_to_root*e.transformation,depth+1)
          end
          break if result
        end
      end

      walker.call(@root.definition.entities,Geom::Transformation.new,0)
      result
    end

    def find_tagged_entities_in_context(ents,role,klass=nil)
      found=[]
      ents.each do |e|
        next if klass && !e.is_a?(klass)
        next unless e.respond_to?(:get_attribute)
        found << e if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
      end
      found
    end

    def update_ridge_drag(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)

      # Topology-safe "flat" limit.
      # A mathematically coplanar ridge can make SketchUp collapse/delete the
      # ridge/gable topology, which then prevents raising it again. Keep a tiny
      # 0.01" gap: visually flat at house scale, but topologically reversible.
      flat_gap=0.01.inch
      min_ridge_z=ctx[:eave_z]+flat_gap
      min_delta=min_ridge_z-ctx[:ridge_z]
      if desired_local < min_delta
        desired_local=min_delta
        Sketchup.status_text='Ridge limit: roof is visually flat (topology preserved).'
      end

      new_ridge_z=ctx[:ridge_z]+desired_local

      lx=ctx[:left_eave_x]
      rx=ctx[:right_eave_x]
      cx=ctx[:ridge_x]

      targets={}

      ctx[:vertices].each do |vv|
        original=ctx[:original_positions][vv]
        next unless original

        x0=original.x
        factor =
          if x0 <= lx
            0.0
          elsif x0 >= rx
            0.0
          elsif x0 <= cx
            (x0-lx)/(cx-lx)
          else
            (rx-x0)/(rx-cx)
          end

        factor=0.0 if factor < 0.0
        factor=1.0 if factor > 1.0

        # MODE 3: the outer eave stays fixed, while every point toward the
        # ridge follows the new slope proportionally. This includes the two
        # continuous inclined soffits.
        # Keep the house floor/base and low wall geometry fixed exactly as in
        # the stable Mode 1 ridge tool. The exception is the explicitly tagged
        # Mode 3 soffit surface: its inner points follow the changing slope.
        z_tol=0.01.inch
        is_mode3_soffit=ctx[:ridge_soffit_vertices].include?(vv)
        factor=0.0 if !is_mode3_soffit && original.z <= (ctx[:eave_z] + z_tol)

        target=original.clone
        target.z=original.z + desired_local*factor
        targets[vv]=target
      end

      mode3_project_soffit_to_plane!('soffit_left',ctx[:original_positions],targets)
      mode3_project_soffit_to_plane!('soffit_right',ctx[:original_positions],targets)
      mode3_apply_targets(ctx[:entities],targets)
      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "Gablehip ridge update error: #{e.message}"
    end


    # Pitch drag raises/lowers the two eave sides while the ridge remains fixed.
    # Base mode is symmetric: clicking either pitch moves BOTH sides together.
    # SHIFT at drag start edits only the clicked side.
    def start_pitch_drag(role,x,y,v,flags)
      selected_ctx=find_edge_context(role)
      opposite_role=(role=='pitch_left' ? 'pitch_right' : 'pitch_left')
      opposite_ctx=find_edge_context(opposite_role)

      unless selected_ctx && opposite_ctx
        UI.beep
        Sketchup.status_text='Both pitch_left and pitch_right must be tagged.'
        return
      end

      unless selected_ctx[:entities] == opposite_ctx[:entities]
        UI.beep
        Sketchup.status_text='Pitch controls must belong to the same geometry context.'
        return
      end

      ents=selected_ctx[:entities]
      local_to_world=selected_ctx[:local_to_world]
      selected_edge=selected_ctx[:edge]
      opposite_edge=opposite_ctx[:edge]

      axis_local=Geom::Vector3d.new(0,0,1)
      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      # Fixed top reference comes from the tagged ridge itself.
      ridge_ctx=find_edge_context('ridge')
      unless ridge_ctx && ridge_ctx[:entities] == ents
        UI.beep
        Sketchup.status_text='Tagged ridge must exist in the same geometry context.'
        return
      end

      ridge_edge=ridge_ctx[:edge]
      ridge_mid=Geom.linear_combination(0.5,ridge_edge.start.position,0.5,ridge_edge.end.position)
      ridge_z=ridge_mid.z
      ridge_x=ridge_mid.x

      # Real eave references come from the tagged roof faces, not from whichever
      # endpoints happened to be used for the pitch control edges.
      roof_faces=find_tagged_entities_in_context(ents,'roof',Sketchup::Face)
      if roof_faces.empty?
        UI.beep
        Sketchup.status_text='No tagged roof faces found.'
        return
      end

      roof_vertices=roof_faces.flat_map(&:vertices).uniq
      left_x=roof_vertices.map{|vv| vv.position.x}.min
      right_x=roof_vertices.map{|vv| vv.position.x}.max
      edge_tol=0.05.inch

      left_eave_vertices=roof_vertices.select{|vv| (vv.position.x-left_x).abs <= edge_tol}
      right_eave_vertices=roof_vertices.select{|vv| (vv.position.x-right_x).abs <= edge_tol}

      left_z=left_eave_vertices.map{|vv| vv.position.z}.max
      right_z=right_eave_vertices.map{|vv| vv.position.z}.max

      if left_z.nil? || right_z.nil? ||
         (ridge_x-left_x).abs < 0.01.inch || (right_x-ridge_x).abs < 0.01.inch
        UI.beep
        Sketchup.status_text='Roof eave/ridge geometry is invalid.'
        return
      end

      asymmetric=((flags & CONSTRAIN_MODIFIER_MASK) != 0)
      selected_side=(role=='pitch_left' ? :left : :right)

      # Only the roof assembly is directly selected for deformation. Shared
      # vertices automatically reshape the top of the gable walls, while the
      # floor/base and unrelated wall vertices remain untouched.
      roof_roles=%w[
        roof
        soffit_left soffit_right
        fascia_front fascia_back fascia_left fascia_right
        ridge pitch_left pitch_right
      ]

      vertices=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless erole && roof_roles.include?(erole)
        case e
        when Sketchup::Face
          e.vertices.each{|vv| vertices << vv}
        when Sketchup::Edge
          vertices << e.start << e.end
        end
      end
      vertices.uniq!

      original_positions={}
      vertices.each{|vv| original_positions[vv]=vv.position.clone }

      # MODE 3:
      # The two side soffits are inclined continuous faces and MUST follow the
      # roof pitch. Therefore they are intentionally NOT treated as rigid strips.
      # Only the side fascias remain rigid.
      rigid_left_vertices=[]
      rigid_right_vertices=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role')
        bucket =
          if erole=='fascia_left'
            rigid_left_vertices
          elsif erole=='fascia_right'
            rigid_right_vertices
          end
        next unless bucket

        case e
        when Sketchup::Face
          e.vertices.each{|vv| bucket << vv}
        when Sketchup::Edge
          bucket << e.start << e.end
        end
      end
      rigid_left_vertices.uniq!
      rigid_right_vertices.uniq!

      # House base is a hard downward safety reference. We compute it from all
      # geometry in this editing context, not only the roof assembly.
      house_base_z=nil
      ents.each do |e|
        next unless e.respond_to?(:bounds)
        z=e.bounds.min.z
        house_base_z=z if house_base_z.nil? || z < house_base_z
      end
      house_base_z ||= 0.0

      # Upward clamp: visually flat, but preserve a tiny non-coplanar gap.
      # If the eaves become mathematically coplanar with the ridge, SketchUp can
      # collapse the front/back gable faces; lowering again then leaves holes.
      flat_gap=0.01.inch
      selected_eave_z=(selected_side==:left ? left_z : right_z)
      max_up_selected=(ridge_z-flat_gap)-selected_eave_z

      if asymmetric
        max_up=[max_up_selected,0.0].max
      else
        max_up=[[(ridge_z-flat_gap)-left_z,(ridge_z-flat_gap)-right_z].min,0.0].max
      end

      # Downward clamp uses the lowest roof-assembly point that receives full
      # movement, but keeps a small safety gap above the house floor.
      full_factor_z=[]
      vertices.each do |vv|
        p=original_positions[vv]
        next unless p
        full =
          if asymmetric
            selected_side==:left ? (p.x <= left_x + 0.02.inch) : (p.x >= right_x - 0.02.inch)
          else
            (p.x <= left_x + 0.02.inch) || (p.x >= right_x - 0.02.inch)
          end
        full_factor_z << p.z if full
      end
      lowest_full=full_factor_z.min || [left_z,right_z].min

      # Same safety philosophy as the wall limits: approach the floor closely,
      # but never let the roof assembly actually touch/cross it.
      house_top_z=nil
      ents.each do |e|
        next unless e.respond_to?(:bounds)
        z=e.bounds.max.z
        house_top_z=z if house_top_z.nil? || z > house_top_z
      end
      house_top_z ||= ridge_z
      house_height=[house_top_z-house_base_z,1.inch].max
      floor_guard=[[house_height*0.02,6.inch].max,12.inch].min
      min_down=(house_base_z+floor_guard)-lowest_full

      selected_mid=Geom.linear_combination(0.5,selected_edge.start.position,0.5,selected_edge.end.position)

      @dragging=true
      @hover_role=role
      @drag_context={
        kind: :pitch,
        role:role,
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:selected_mid.transform(local_to_world),
        local_to_world:local_to_world,
        ridge_x:ridge_x,
        ridge_z:ridge_z,
        left_x:left_x,
        right_x:right_x,
        left_z:left_z,
        right_z:right_z,
        rigid_left_vertices:rigid_left_vertices,
        rigid_right_vertices:rigid_right_vertices,
        selected_side:selected_side,
        asymmetric:asymmetric,
        max_up:max_up,
        min_down:min_down,
        start_parameter:nil,
        current_delta_local:0.0
      }

      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation(
        asymmetric ? "Adjust #{role} asymmetrically" : 'Adjust roof pitch symmetrically',
        true
      )
      @op_open=true
      rebuild_draw_items

      if asymmetric
        Sketchup.status_text="ASYMMETRIC pitch: only #{role} follows. Ridge stays fixed."
      else
        Sketchup.status_text='MODE 3 PITCH: both eaves move together; inclined soffits follow the roof slope. SHIFT = one side only.'
      end
    rescue => e
      cancel_drag
      UI.messagebox("Pitch deformation error:
#{e.message}")
    end

    def update_pitch_drag(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)

      # Hard limits.
      if desired_local > ctx[:max_up]
        desired_local=ctx[:max_up]
        Sketchup.status_text='Pitch upper limit: roof is visually flat (topology preserved).'
      elsif desired_local < ctx[:min_down]
        desired_local=ctx[:min_down]
        Sketchup.status_text='Pitch lower limit: safety gap above the house floor reached.'
      end

      lx=ctx[:left_x]
      rx=ctx[:right_x]
      cx=ctx[:ridge_x]
      selected_side=ctx[:selected_side]
      asymmetric=ctx[:asymmetric]

      moved=[]
      vectors=[]

      ctx[:vertices].each do |vv|
        original=ctx[:original_positions][vv]
        next unless original

        x0=original.x
        factor=0.0

        if asymmetric
          if selected_side==:left
            if x0 <= lx
              factor=1.0
            elsif x0 < cx
              factor=(cx-x0)/(cx-lx)
            end
          else
            if x0 >= rx
              factor=1.0
            elsif x0 > cx
              factor=(x0-cx)/(rx-cx)
            end
          end
        else
          if x0 <= lx
            factor=1.0
          elsif x0 < cx
            factor=(cx-x0)/(cx-lx)
          elsif x0 >= rx
            factor=1.0
          elsif x0 > cx
            factor=(x0-cx)/(rx-cx)
          else
            factor=0.0
          end
        end

        # Preserve side soffit/fascia rectitude: translate the complete strip
        # as a rigid vertical band instead of interpolating across its width.
        if ctx[:rigid_left_vertices].include?(vv)
          factor = (!asymmetric || selected_side==:left) ? 1.0 : 0.0
        elsif ctx[:rigid_right_vertices].include?(vv)
          factor = (!asymmetric || selected_side==:right) ? 1.0 : 0.0
        end

        factor=0.0 if factor < 0.0
        factor=1.0 if factor > 1.0

        # Keep the ridge itself mathematically fixed even if connected faces
        # share its vertices.
        factor=0.0 if (x0-cx).abs <= 0.01.inch

        target=original.clone
        target.z=original.z + desired_local*factor

        delta=vv.position.vector_to(target)
        next if delta.length < 1.0e-9
        moved << vv
        vectors << delta
      end

      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "Gablehip pitch update error: #{e.message}"
    end


    # Fascia drag changes overhang/depth, not height.
    # Base mode is symmetric:
    #   front <-> back move outward/inward together
    #   left  <-> right move outward/inward together
    # SHIFT at drag start edits only the clicked fascia.
    def start_fascia_drag(role,x,y,v,flags)
      selected=find_face_context(role)
      unless selected
        UI.beep
        Sketchup.status_text='Could not find tagged fascia face.'
        return
      end

      pair_role =
        case role
        when 'fascia_front' then 'fascia_back'
        when 'fascia_back'  then 'fascia_front'
        when 'fascia_left'  then 'fascia_right'
        when 'fascia_right' then 'fascia_left'
        end

      opposite=find_face_context(pair_role)
      unless opposite && opposite[:entities] == selected[:entities]
        UI.beep
        Sketchup.status_text='Opposite fascia must be tagged in the same geometry context.'
        return
      end

      ents=selected[:entities]
      local_to_world=selected[:local_to_world]
      selected_face=selected[:face]
      opposite_face=opposite[:face]

      axis_name = %w[fascia_left fascia_right].include?(role) ? :x : :y
      axis_local =
        axis_name==:x ? Geom::Vector3d.new(1,0,0) : Geom::Vector3d.new(0,1,0)

      # Determine which sign is OUTWARD for the clicked fascia from its center
      # relative to the component/context center. This stays robust even if the
      # template's front/back naming does not match world +Y/-Y.
      center=context_bounds_center(ents)
      sel_center=selected_face.bounds.center
      sel_coord=(axis_name==:x ? sel_center.x : sel_center.y)
      ctr_coord=(axis_name==:x ? center.x : center.y)
      outward_sign=(sel_coord >= ctr_coord ? 1.0 : -1.0)

      # Mouse axis follows the selected fascia's outward direction.
      outward_axis_local=Geom::Vector3d.new(
        axis_local.x*outward_sign,
        axis_local.y*outward_sign,
        axis_local.z*outward_sign
      )
      axis_world=outward_axis_local.transform(local_to_world)
      axis_world.normalize!

      asymmetric=((flags & CONSTRAIN_MODIFIER_MASK) != 0)

      # Locate the corresponding wall planes. These become the inward safety
      # stops so a fascia can approach the wall but never cross through it.
      wall_role =
        case role
        when 'fascia_front' then 'wall_front'
        when 'fascia_back'  then 'wall_back'
        when 'fascia_left'  then 'wall_left'
        when 'fascia_right' then 'wall_right'
        end

      pair_wall_role =
        case pair_role
        when 'fascia_front' then 'wall_front'
        when 'fascia_back'  then 'wall_back'
        when 'fascia_left'  then 'wall_left'
        when 'fascia_right' then 'wall_right'
        end

      wall_ctx=find_face_context(wall_role)
      pair_wall_ctx=find_face_context(pair_wall_role)

      unless wall_ctx && pair_wall_ctx &&
             wall_ctx[:entities] == ents && pair_wall_ctx[:entities] == ents
        UI.beep
        Sketchup.status_text='Matching wall tags are required for fascia safety limits.'
        return
      end

      coord=lambda do |face|
        c=face.bounds.center
        axis_name==:x ? c.x : c.y
      end

      sel_fascia_plane=coord.call(selected_face)
      opp_fascia_plane=coord.call(opposite_face)
      sel_wall_plane=coord.call(wall_ctx[:face])
      opp_wall_plane=coord.call(pair_wall_ctx[:face])

      # Tiny but visible-safe minimum overhang. Keep enough space that connected
      # roof/soffit topology never collapses into the wall plane.
      sel_overhang=(sel_fascia_plane-sel_wall_plane).abs
      opp_overhang=(opp_fascia_plane-opp_wall_plane).abs
      min_overhang=[[ [sel_overhang,opp_overhang].min * 0.02, 0.25.inch].max, 1.0.inch].min

      # Gather fascia vertices. Shared raw-geometry vertices make adjacent roof
      # and soffit faces stretch with the fascia automatically, preserving
      # connection without translating the whole roof.
      selected_vertices=selected_face.vertices.uniq
      opposite_vertices=opposite_face.vertices.uniq
      all_vertices=(selected_vertices+opposite_vertices).uniq

      original_positions={}
      all_vertices.each{|vv| original_positions[vv]=vv.position.clone}
      wall_vertices=[]
      if axis_name==:x
        mode3_collect_extra_originals(
          original_positions,
          'soffit_left','soffit_right','roof'
        )
        wall_vertices=mode3_wall_vertices_in_context(ents)
        wall_vertices.each{|vv| original_positions[vv] ||= vv.position.clone}

        ridge_ctx=find_edge_context('ridge')
        if ridge_ctx && ridge_ctx[:entities] == ents
          original_positions[ridge_ctx[:edge].start] ||= ridge_ctx[:edge].start.position.clone
          original_positions[ridge_ctx[:edge].end]   ||= ridge_ctx[:edge].end.position.clone
        end
      end

      origin_world=selected_face.bounds.center.transform(local_to_world)

      @dragging=true
      @hover_role=role
      @drag_context={
        kind: :fascia,
        role:role,
        pair_role:pair_role,
        entities:ents,
        selected_vertices:selected_vertices,
        opposite_vertices:opposite_vertices,
        original_positions:original_positions,
        mode3_wall_vertices:wall_vertices,
        axis_name:axis_name,
        outward_sign:outward_sign,
        axis_local:outward_axis_local,
        axis_world:axis_world,
        origin_world:origin_world,
        local_to_world:local_to_world,
        asymmetric:asymmetric,
        sel_fascia_plane:sel_fascia_plane,
        opp_fascia_plane:opp_fascia_plane,
        sel_wall_plane:sel_wall_plane,
        opp_wall_plane:opp_wall_plane,
        min_overhang:min_overhang,
        start_parameter:nil,
        current_delta_local:0.0
      }

      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation(
        asymmetric ? "Adjust #{role} individually" : 'Adjust fascia pair symmetrically',
        true
      )
      @op_open=true
      rebuild_draw_items

      if asymmetric
        Sketchup.status_text="INDIVIDUAL fascia: #{role}. Drag out/in; matching fascia stays fixed."
      else
        Sketchup.status_text="MODE 3 fascia: inverted-V solver; ridge fixed, fascia opens/closes pitch. SHIFT = individual."
      end
    rescue => e
      cancel_drag
      UI.messagebox("Fascia deformation error:
#{e.message}")
    end

    def find_face_context(role)
      result=nil

      walker=lambda do |ents, local_to_root, depth|
        return if depth>30 || result
        ents.each do |e|
          case e
          when Sketchup::Face
            if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
              result={
                face:e,
                entities:ents,
                local_to_root:local_to_root,
                local_to_world:@root.transformation * local_to_root
              }
              break
            end
          when Sketchup::Group
            walker.call(e.entities,local_to_root*e.transformation,depth+1)
          when Sketchup::ComponentInstance
            walker.call(e.definition.entities,local_to_root*e.transformation,depth+1)
          end
          break if result
        end
      end

      walker.call(@root.definition.entities,Geom::Transformation.new,0)
      result
    end


    def mode3_wall_vertices_in_context(ents)
      roles=%w[wall_front wall_back wall_left wall_right]
      out=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        role=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless role && roles.include?(role)
        case e
        when Sketchup::Face
          e.vertices.each{|v|out << v}
        when Sketchup::Edge
          out << e.start << e.end
        end
      end
      out.uniq
    end


    def mode3_plane_z_value(plane,x,y)
      return nil unless plane && plane.length>=4
      a,b,c,d=plane
      return nil if c.abs < 1.0e-9
      -(a*x+b*y+d)/c
    end

    def mode3_shared_vertices(face_a,face_b)
      return [] unless face_a && face_b
      face_a.vertices & face_b.vertices
    end

    def mode3_matching_roof_face_for_fascia(ents,fascia_face)
      roofs=find_tagged_entities_in_context(ents,'roof',Sketchup::Face)
      roofs.max_by{|rf| (rf.vertices & fascia_face.vertices).length}
    end

    def update_fascia_drag(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)

      axis_name=ctx[:axis_name]
      sign=ctx[:outward_sign]

      # Keep the proven inward safety limits.
      current_sel=ctx[:sel_fascia_plane] + desired_local*sign
      sel_distance=(current_sel-ctx[:sel_wall_plane]).abs
      sel_cross=((ctx[:sel_fascia_plane]-ctx[:sel_wall_plane]) *
                 (current_sel-ctx[:sel_wall_plane])) <= 0.0

      if sel_cross || sel_distance < ctx[:min_overhang]
        original_signed=(ctx[:sel_fascia_plane]-ctx[:sel_wall_plane])*sign
        desired_local=ctx[:min_overhang]-original_signed
        Sketchup.status_text='Fascia inward limit: minimum safe overhang reached.'
      end

      unless ctx[:asymmetric]
        pair_sign=-sign
        current_opp=ctx[:opp_fascia_plane] + desired_local*pair_sign
        opp_distance=(current_opp-ctx[:opp_wall_plane]).abs
        opp_cross=((ctx[:opp_fascia_plane]-ctx[:opp_wall_plane]) *
                   (current_opp-ctx[:opp_wall_plane])) <= 0.0

        if opp_cross || opp_distance < ctx[:min_overhang]
          original_opp_signed=(ctx[:opp_fascia_plane]-ctx[:opp_wall_plane])*pair_sign
          safe_pair=ctx[:min_overhang]-original_opp_signed
          desired_local=[desired_local,safe_pair].max
          Sketchup.status_text='Fascia inward limit: minimum safe overhang reached.'
        end
      end

      targets={}

      # Front/back fascias keep the original Mode 1 behavior.
      if axis_name!=:x
        ctx[:selected_vertices].each do |vv|
          original=ctx[:original_positions][vv]
          next unless original
          p=original.clone
          p.y=original.y + desired_local*sign
          targets[vv]=p
        end

        unless ctx[:asymmetric]
          pair_sign=-sign
          ctx[:opposite_vertices].each do |vv|
            original=ctx[:original_positions][vv]
            next unless original
            p=original.clone
            p.y=original.y + desired_local*pair_sign
            targets[vv]=p
          end
        end
      else
        # MODE 3 SIDE FASCIA — V CROSS-SECTION SOLVER
        #
        # Ridge is fixed.
        # Fascia/eave moves horizontally.
        # Roof plane is rebuilt from fixed ridge + moved eave.
        # The continuous inclined soffit becomes a plane PARALLEL to that roof.
        # Its inner wall boundary keeps X/Y fixed and only changes Z.
        # Therefore the house does not translate or skew: the inverted V simply
        # opens/closes and naturally loses/gains pitch.
        pairs=[
          ['fascia_left','soffit_left','wall_left'],
          ['fascia_right','soffit_right','wall_right']
        ]

        ridge_ctx=find_edge_context('ridge')
        ridge_edge=(ridge_ctx && ridge_ctx[:entities]==ctx[:entities]) ? ridge_ctx[:edge] : nil

        pairs.each do |frole,srole,wrole|
          active=(frole==ctx[:role]) || (!ctx[:asymmetric] && frole==ctx[:pair_role])
          next unless active

          fctx=find_face_context(frole)
          sctx=find_face_context(srole)
          wctx=find_face_context(wrole)
          next unless fctx && sctx && wctx && ridge_edge
          next unless fctx[:entities]==ctx[:entities] &&
                      sctx[:entities]==ctx[:entities] &&
                      wctx[:entities]==ctx[:entities]

          fascia=fctx[:face]
          soffit=sctx[:face]
          wall=wctx[:face]
          roof=mode3_matching_roof_face_for_fascia(ctx[:entities],fascia)
          next unless roof

          move_sign=(frole==ctx[:role]) ? sign : -sign

          # 1) Move the side fascia rigidly in X. No Z scaling of fascia.
          fascia.vertices.each do |vv|
            original=ctx[:original_positions][vv] || vv.position.clone
            p=original.clone
            p.x=original.x + desired_local*move_sign
            targets[vv]=p
          end

          # 2) Rebuild the matching roof slope from:
          #    fixed ridge edge + moved outer roof/fascia boundary.
          roof_fascia_shared=mode3_shared_vertices(roof,fascia)
          next if roof_fascia_shared.empty?

          r1=ctx[:original_positions][ridge_edge.start] || ridge_edge.start.position.clone
          r2=ctx[:original_positions][ridge_edge.end]   || ridge_edge.end.position.clone

          eave_v=roof_fascia_shared.first
          eave_original=ctx[:original_positions][eave_v] || eave_v.position.clone
          eave_target=targets[eave_v] || begin
            p=eave_original.clone
            p.x=eave_original.x + desired_local*move_sign
            p
          end

          new_roof_plane=Geom.fit_plane_to_points([r1,r2,eave_target])
          next unless new_roof_plane

          # Original roof plane is used only for affine X mapping of any
          # intermediate roof vertices; Z comes from the NEW exact plane.
          ridge_x=(r1.x+r2.x)*0.5
          outer_orig_x=roof_fascia_shared.map{|v|(ctx[:original_positions][v]||v.position).x}.sum /
                       roof_fascia_shared.length.to_f
          outer_new_x=outer_orig_x + desired_local*move_sign
          denom=outer_orig_x-ridge_x

          roof.vertices.each do |vv|
            original=ctx[:original_positions][vv] || vv.position.clone
            p=original.clone

            if (ridge_edge.vertices.include?(vv) rescue false)
              p=original.clone
            else
              t=denom.abs<1.0e-9 ? 1.0 : (original.x-ridge_x)/denom
              p.x=ridge_x + t*(outer_new_x-ridge_x)
              z=mode3_plane_z_value(new_roof_plane,p.x,p.y)
              p.z=z if z
            end
            targets[vv]=p
          end

          # 3) Soffit boundaries from REAL topology.
          outer_shared=mode3_shared_vertices(soffit,fascia)
          inner_shared=mode3_shared_vertices(soffit,wall)
          next if outer_shared.empty? || inner_shared.empty?

          inner_orig_x=inner_shared.map{|v|(ctx[:original_positions][v]||v.position).x}.sum /
                       inner_shared.length.to_f
          outer_soffit_orig_x=outer_shared.map{|v|(ctx[:original_positions][v]||v.position).x}.sum /
                              outer_shared.length.to_f
          soffit_denom=outer_soffit_orig_x-inner_orig_x

          # Build a soffit plane PARALLEL to the new roof plane, anchored at
          # the moved outer soffit/fascia boundary. Same pitch, no twist.
          anchor_v=outer_shared.first
          anchor_original=ctx[:original_positions][anchor_v] || anchor_v.position.clone
          anchor_target=targets[anchor_v] || begin
            p=anchor_original.clone
            p.x=anchor_original.x + desired_local*move_sign
            p
          end

          a,b,c,_d=new_roof_plane
          soffit_d=-(a*anchor_target.x + b*anchor_target.y + c*anchor_target.z)
          new_soffit_plane=[a,b,c,soffit_d]

          soffit.vertices.each do |vv|
            original=ctx[:original_positions][vv] || vv.position.clone
            p=original.clone

            factor =
              if inner_shared.include?(vv)
                0.0
              elsif outer_shared.include?(vv)
                1.0
              elsif soffit_denom.abs<1.0e-9
                0.0
              else
                (original.x-inner_orig_x)/soffit_denom
              end
            factor=0.0 if factor<0.0
            factor=1.0 if factor>1.0

            # Inner wall boundary stays in place horizontally; outer edge follows
            # fascia; everything between stretches linearly.
            p.x=original.x + desired_local*move_sign*factor
            z=mode3_plane_z_value(new_soffit_plane,p.x,p.y)
            p.z=z if z
            targets[vv]=p
          end

          # 4) Walls do NOT move sideways. Only wall vertices that are actually
          # shared with the inclined soffit are allowed to change Z so the wall
          # naturally fills the opening under the flatter/steeper V.
          wall.vertices.each do |vv|
            original=ctx[:original_positions][vv] || vv.position.clone
            if inner_shared.include?(vv)
              p=targets[vv] || original.clone
              p.x=original.x
              p.y=original.y
              z=mode3_plane_z_value(new_soffit_plane,p.x,p.y)
              p.z=z if z
              targets[vv]=p
            else
              targets[vv]=original.clone unless targets.key?(vv)
            end
          end
        end
      end

      moved=[]
      vectors=[]
      targets.each do |vv,target|
        delta=vv.position.vector_to(target)
        next if delta.length < 1.0e-9
        moved << vv
        vectors << delta
      end
      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?

      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "Gablehip fascia update error: #{e.message}"
    end


    def context_bounds_center(ents)
      bb=Geom::BoundingBox.new

      ents.each do |e|
        next unless e.respond_to?(:bounds)
        b=e.bounds
        bb.add(b.min)
        bb.add(b.max)
      end

      bb.center
    end



    # ----------------------------------------------------------------------
    # MODE 3 — planar inclined soffit correction
    #
    # Each side soffit is ONE continuous inclined face. For width and side-
    # fascia edits we move its boundary in X and then rebuild ONE exact plane
    # from three semantic anchors. This prevents SketchUp Auto-Fold from
    # inserting diagonal edges.
    # ----------------------------------------------------------------------

    def mode3_face_ctx(role)
      find_face_context(role)
    rescue
      nil
    end

    def mode3_collect_extra_originals(originals, *roles)
      roles.flatten.each do |role|
        c=mode3_face_ctx(role)
        next unless c
        c[:face].vertices.each do |v|
          originals[v] ||= v.position.clone
        end
      end
    end

    def mode3_side_outer_x(points, role)
      xs=points.map(&:x)
      role=='soffit_left' ? xs.min : xs.max
    end

    def mode3_side_inner_x(points, role)
      xs=points.map(&:x)
      role=='soffit_left' ? xs.max : xs.min
    end

    def mode3_project_soffit_to_plane!(role, originals, targets)
      ctx=mode3_face_ctx(role)
      return unless ctx
      verts=ctx[:face].vertices
      return if verts.length < 3

      pts=verts.map{|v| targets[v] || originals[v] || v.position.clone}
      outer_x=mode3_side_outer_x(pts,role)
      inner_x=mode3_side_inner_x(pts,role)
      tol=[(outer_x-inner_x).abs*0.001, 0.02.inch].max

      outer=[]
      inner=[]
      verts.each do |v|
        p=targets[v] || originals[v] || v.position.clone
        outer << [v,p] if (p.x-outer_x).abs <= tol
        inner << [v,p] if (p.x-inner_x).abs <= tol
      end
      return if outer.length < 2 || inner.empty?

      # Two points along the outer boundary + one point from the inner boundary
      # define the intended soffit plane exactly.
      outer_sorted=outer.sort_by{|vp| vp[1].y}
      a=outer_sorted.first[1]
      b=outer_sorted.last[1]

      # Pick the inner point farthest in Y from A so the three anchors are
      # robustly non-collinear.
      c=inner.max_by{|vp| (vp[1].y-a.y).abs}[1]

      plane=Geom.fit_plane_to_points([a,b,c])
      return unless plane && plane.length>=4
      aa,bb,cc,dd=plane
      return if cc.abs < 1.0e-9

      verts.each do |v|
        base=targets[v] || originals[v] || v.position.clone
        z=-(aa*base.x + bb*base.y + dd)/cc
        p=base.clone
        p.z=z
        targets[v]=p
      end
    rescue => e
      puts "Mode3 soffit plane correction error: #{e.message}"
    end


    def mode3_apply_targets(ents,targets)
      moved=[]
      vectors=[]
      targets.each do |v,target|
        delta=v.position.vector_to(target)
        next if delta.length < 1.0e-9
        moved << v
        vectors << delta
      end
      ents.transform_by_vectors(moved,vectors) unless moved.empty?
    end

    def clear_snap_state
      @snap_point_world=nil
      @snap_label=nil
      @snap_target_role=nil
      @snap_target_face=nil
      @snap_target_tr=nil
    end

    def entity_role(e)
      return nil unless e && e.respond_to?(:get_attribute)
      e.get_attribute(Gablehip::ATTR_DICT,'role')
    end

    def picked_role_context(v,x,y,wanted)
      roles=Array(wanted)
      ph=v.pick_helper
      ph.do_pick(x,y)
      ph.count.times do |i|
        path=ph.path_at(i)
        next unless path && path.include?(@root)
        e=path.last
        role=entity_role(e)
        return [role,e,path] if role && roles.include?(role)
      end
      nil
    rescue
      nil
    end

    def current_role_snap_point(role)
      if PITCH_ROLES.include?(role) || role=='ridge'
        c=find_edge_context(role)
        return nil unless c
        e=c[:edge]
        Geom.linear_combination(0.5,e.start.position,0.5,e.end.position).transform(c[:local_to_world])
      else
        c=find_face_context(role)
        return nil unless c
        c[:face].bounds.center.transform(c[:local_to_world])
      end
    rescue
      nil
    end

    def local_axis_world_scale(ctx)
      a=ctx[:axis_local].clone
      a.length=1.0
      w=a.transform(ctx[:local_to_world])
      s=w.length
      s.abs<1.0e-9 ? 1.0 : s
    end

    def semantic_snap(x,y,v,ctx)
      if ctx[:kind]==:pitch && ctx[:asymmetric]
        other=(ctx[:role]=='pitch_left' ? 'pitch_right' : 'pitch_left')
        if picked_role_context(v,x,y,[other])
          a=(ctx[:selected_side]==:left ? ctx[:left_z] : ctx[:right_z])
          b=(ctx[:selected_side]==:left ? ctx[:right_z] : ctx[:left_z])
          return {delta_local:b-a,point_world:current_role_snap_point(other),label:'SNAP: PITCH SYMMETRY'}
        end
      end

      if ctx[:kind]==:fascia && ctx[:asymmetric] && ctx[:pair_role]
        if picked_role_context(v,x,y,[ctx[:pair_role]])
          s=ctx[:outward_sign]; ps=-s
          a=(ctx[:sel_fascia_plane]-ctx[:sel_wall_plane])*s
          b=(ctx[:opp_fascia_plane]-ctx[:opp_wall_plane])*ps
          return {delta_local:b-a,point_world:current_role_snap_point(ctx[:pair_role]),label:'SNAP: FASCIA SYMMETRY'}
        end
      end

      if ctx[:kind]==:soffit && ctx[:asymmetric]
        hit=picked_role_context(v,x,y,SOFFIT_ROLES.reject{|r|r==ctx[:role]})
        if hit
          target=current_role_snap_point(hit[0])
          if target
            delta=ctx[:origin_world].vector_to(target).dot(ctx[:axis_world])/local_axis_world_scale(ctx)
            return {delta_local:delta,point_world:target,label:'SNAP: SOFFIT LEVEL'}
          end
        end
      end
      nil
    rescue => e
      puts "Gablehip semantic snap error: #{e.message}"
      nil
    end

    def external_geometry_snap(x,y,v,ctx)
      ph=v.pick_helper
      ph.do_pick(x,y)

      # DIRECT SPATIAL FACE SNAP.
      # The manipulator NEVER changes its permitted axis. We only solve the
      # scalar distance along ctx[:axis_world] required for the dragged anchor
      # to reach the plane under the cursor.
      ph.count.times do |i|
        path=ph.path_at(i)
        next unless path
        next if path.include?(@root)

        face=path.reverse.find{|node| node.is_a?(Sketchup::Face)}
        next unless face && face.valid?

        tr=Geom::Transformation.new
        path.each do |node|
          if node.is_a?(Sketchup::Group) || node.is_a?(Sketchup::ComponentInstance)
            tr=tr*node.transformation
          end
          break if node.equal?(face)
        end

        p0=face.vertices.first.position.transform(tr)
        normal=face.normal.transform(tr)
        next if normal.length<1.0e-9
        normal.normalize!

        axis=ctx[:axis_world].clone
        next if axis.length<1.0e-9
        axis.normalize!

        denom=axis.dot(normal)
        # Parallel movement cannot ever reach this plane without violating the
        # manipulator constraint, so do not invent another axis.
        next if denom.abs<1.0e-7

        anchor=ctx[:snap_anchor_world] || ctx[:origin_world]
        distance=anchor.vector_to(p0).dot(normal)/denom
        target=anchor.offset(axis,distance)
        delta=anchor.vector_to(target).dot(ctx[:axis_world])/local_axis_world_scale(ctx)

        @snap_target_face=face
        @snap_target_tr=tr
        @snap_target_role=entity_role(face)
        return {delta_local:delta,point_world:target,label:'SNAP: FACE'}
      end

      # Preserve R2C vertex/edge inference fallback, still projected strictly
      # onto the current manipulator axis.
      ip=Sketchup::InputPoint.new
      ip.pick(v,x,y)
      return nil unless ip.valid?
      begin
        return nil unless ip.vertex || ip.edge || ip.face
      rescue
        return nil
      end
      ph.count.times do |i|
        path=ph.path_at(i)
        return nil if path && path.include?(@root)
      end
      target=ip.position
      anchor=ctx[:snap_anchor_world] || ctx[:origin_world]
      delta=anchor.vector_to(target).dot(ctx[:axis_world])/local_axis_world_scale(ctx)
      {delta_local:delta,point_world:target.clone,label:'SNAP: MODEL GEOMETRY'}
    rescue => e
      puts "Gablehip external snap error: #{e.message}"
      nil
    end

    def desired_local_from_mouse(x,y,v,ctx)
      current=mouse_axis_parameter(x,y,v,ctx)
      desired=(current-ctx[:start_parameter])/local_axis_world_scale(ctx)
      snap=semantic_snap(x,y,v,ctx) || external_geometry_snap(x,y,v,ctx)
      if snap
        @snap_point_world=snap[:point_world]
        @snap_label=snap[:label]
        v.tooltip=@snap_label rescue nil
        snap[:delta_local]
      else
        clear_snap_state
        desired
      end
    end

    def mouse_axis_parameter(x,y,v,ctx)
      ray=v.pickray(x,y)
      ray_origin=ray[0]
      ray_dir=ray[1]
      axis_origin=ctx[:origin_world]
      axis_dir=ctx[:axis_world]

      w0=ray_origin-axis_origin
      a=ray_dir.dot(ray_dir)
      b=ray_dir.dot(axis_dir)
      c=axis_dir.dot(axis_dir)
      d=ray_dir.dot(w0)
      e=axis_dir.dot(w0)
      denom=a*c-b*b

      if denom.abs>1.0e-9
        (a*e-b*d)/denom
      else
        @parallel_start_x ||= x
        pixels=x-@parallel_start_x
        pixels*v.pixels_to_model(1.0,axis_origin)
      end
    end

    def update_drag(x,y,v)
      return unless @dragging && @drag_context

      ctx=@drag_context

      if ctx[:kind]==:floor
        update_floor_drag(x,y,v,ctx)
        return
      elsif ctx[:kind]==:roof
        update_roof_drag(x,y,v,ctx)
        return
      elsif ctx[:kind]==:ridge
        update_ridge_drag(x,y,v,ctx)
        return
      elsif ctx[:kind]==:pitch
        update_pitch_drag(x,y,v,ctx)
        return
      elsif ctx[:kind]==:fascia
        update_fascia_drag(x,y,v,ctx)
        return
      elsif ctx[:kind]==:soffit
        update_soffit_drag(x,y,v,ctx)
        return
      end

      desired_local=desired_local_from_mouse(x,y,v,ctx)

      # SAFETY LIMIT: the selected wall is not allowed to meet or pass its
      # opposite wall. If the user pushes into the guard zone, abort the whole
      # drag operation. SketchUp restores the exact drag-start geometry, which
      # avoids collapsed faces, inverted topology and recovery drift.
      if ctx[:opposite_plane] && ctx[:min_span]
        effective_min_span = (ctx[:asymmetric] && !ctx[:front_back]) ? (ctx[:fascia_safe_span] || 0.1.inch) : ctx[:min_span]
        new_selected_plane=ctx[:selected_plane] + desired_local
        new_span=(new_selected_plane-ctx[:opposite_plane]).abs
        crossed=((ctx[:selected_plane]-ctx[:opposite_plane]) *
                 (new_selected_plane-ctx[:opposite_plane])) <= 0.0

        if crossed || new_span <= effective_min_span
          role=ctx[:role]
          if @op_open
            Sketchup.active_model.abort_operation
            @op_open=false
          end
          @dragging=false
          @drag_context=nil
          @parallel_start_x=nil
          @hover_role=role
          rebuild_draw_items
          UI.beep
          Sketchup.status_text='Safety limit reached: walls cannot cross. Geometry restored.'
          return
        end
      end

      axis=ctx[:axis_local]
      sel=ctx[:selected_plane]
      opp=ctx[:opposite_plane]
      tol=ctx[:tolerance]

      targets={}

      ctx[:vertices].each do |vv|
        original=ctx[:original_positions][vv]
        next unless original

        p=original.vector_to(ORIGIN).reverse.dot(axis)
        factor=0.0

        if ctx[:front_back] || ctx[:asymmetric]
          factor=1.0 if p >= (sel - tol)
        elsif opp
          denom=sel-opp
          if denom.abs > 1.0e-9
            if p <= opp + tol
              factor=0.0
            elsif p >= sel - tol
              factor=1.0
            else
              factor=(p-opp)/denom
              factor=0.0 if factor < 0.0
              factor=1.0 if factor > 1.0
            end
          end
        else
          factor=1.0 if p >= (sel - tol)
        end

        target=original.clone
        if factor.abs > 1.0e-9
          offset=axis.clone
          offset.length=desired_local*factor
          target=original+offset
        end
        targets[vv]=target
      end

      # Only lateral width edits need the Mode 3 plane correction.
      unless ctx[:front_back]
        # The two continuous soffits must remain single planes.
        mode3_project_soffit_to_plane!('soffit_left',ctx[:original_positions],targets)
        mode3_project_soffit_to_plane!('soffit_right',ctx[:original_positions],targets)
      end

      mode3_apply_targets(ctx[:entities],targets)

      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "Gablehip drag update error: #{e.message}"
    end

    def finish_drag
      if @op_open
        Sketchup.active_model.commit_operation
        @op_open=false
      end

      role=@drag_context ? @drag_context[:role] : 'control'
      kind=@drag_context ? @drag_context[:kind] : nil
      @dragging=false
      @drag_context=nil
      @parallel_start_x=nil
      clear_snap_state

      if kind==:roof
        Sketchup.status_text='Whole roof height adjusted. Roof shape preserved.'
      elsif kind==:ridge
        Sketchup.status_text='Ridge height adjusted. Hover another control or click outside to exit.'
      elsif kind==:pitch
        Sketchup.status_text='Roof pitch adjusted. Hover another control or click outside to exit.'
      elsif kind==:fascia
        Sketchup.status_text='Fascia overhang adjusted. Hover another control or click outside to exit.'
      elsif kind==:soffit
        Sketchup.status_text='Soffit height adjusted. Faces preserved flat and straight.'
      else
        Sketchup.status_text="#{role} resized the house. Hover another control or click outside to exit."
      end
      rebuild_draw_items
    end

    def cancel_drag
      if @op_open
        Sketchup.active_model.abort_operation
        @op_open=false
      end
      @dragging=false
      @drag_context=nil
      @parallel_start_x=nil
      clear_snap_state
      Sketchup.status_text='Drag cancelled.'
      rebuild_draw_items
    rescue
      @dragging=false
      @drag_context=nil
      @op_open=false
    end
  end
end
