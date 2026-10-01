require 'sketchup.rb'
require_relative 'semantic_drag_tool'

module Gablehip
  class HipDragTool < SemanticDragTool
    HIP_ROOFS=%w[roof_front roof_back roof_left roof_right].freeze
    HIP_PITCHES=%w[pitch_front pitch_back pitch_left pitch_right].freeze
    HIP_FASCIAS=%w[fascia_front fascia_back fascia_left fascia_right].freeze
    HIP_SOFFITS=%w[soffit_front soffit_back soffit_left soffit_right].freeze
    PYRAMID_RIDGE_EPSILON=0.01.inch
    FASCIA_WALL_EPSILON=0.05.inch

    def activate
      super
      Sketchup.status_text='HIP v2.2.9 · Walls + Floor + Roof Height + Soffit Height enabled. Topology-safe pyramid limit active.'
    end

    def group_roles(role)
      return HIP_PITCHES if HIP_PITCHES.include?(role)
      return HIP_FASCIAS if HIP_FASCIAS.include?(role)
      return HIP_SOFFITS if HIP_SOFFITS.include?(role)
      return HIP_ROOFS if %w[roof_left roof_right].include?(role)
      return %w[roof_front roof_back] if %w[roof_front roof_back].include?(role)
      [role]
    end

    def onLButtonDown(flags,x,y,v)
      role=(@alt_wireframe ? pick_role_alt(v,x,y) : pick_role(v,x,y))
      unless role
        SelectionObserver.suspend { Sketchup.active_model.selection.clear }
        Sketchup.active_model.select_tool(nil)
        return
      end
      # Left/right roof faces are the Hip whole-roof height control.
      # Front/back roof faces stay reserved for the future ridge-length control.
      if %w[roof_left roof_right].include?(role)
        start_hip_roof_height_drag(x,y,v)
        return
      end

      if %w[roof_front roof_back].include?(role)
        start_hip_ridge_length_drag(role,x,y,v,flags)
        return
      end

      if HIP_SOFFITS.include?(role)
        start_hip_soffit_height_drag(x,y,v)
        return
      end

      if HIP_FASCIAS.include?(role)
        start_hip_fascia_drag(role,x,y,v)
        return
      end

      if HIP_PITCHES.include?(role)
        start_hip_pitch_drag(role,x,y,v)
        return
      end

      if role=='ridge'
        start_hip_ridge_height_drag(x,y,v)
        return
      end

      unless role==FLOOR_ROLE || WALL_ROLES.include?(role)
        @hover_role=role
        rebuild_draw_items
        UI.beep
        Sketchup.status_text="HIP v2.2.9 · #{role} recognized, but locked in this stage."
        v.invalidate
        return
      end

      super
      prepare_hip_length_ridge if @drag_context && @drag_context[:kind]==:wall &&
                                   %w[wall_front wall_back].include?(@drag_context[:role])
    end

    def logical_name(role)
      return 'Hip floor / house base' if role==FLOOR_ROLE
      return role.sub('wall_','Hip wall ') if WALL_ROLES.include?(role)
      return 'Hip pitch (all 4)' if HIP_PITCHES.include?(role)
      return 'Hip fascia (all 4)' if HIP_FASCIAS.include?(role)
      return 'Hip soffit (all 4)' if HIP_SOFFITS.include?(role)
      return 'Hip roof height (all 4)' if %w[roof_left roof_right].include?(role)
      return 'Hip ridge length (front + back)' if %w[roof_front roof_back].include?(role)
      "Hip #{role}"
    end

    def update_drag(x,y,v)
      ctx=@drag_context
      if ctx && ctx[:kind]==:wall && ctx[:hip_length_ridge]
        update_hip_length_wall(x,y,v,ctx)
      elsif ctx && ctx[:kind]==:hip_roof_height
        update_hip_roof_height(x,y,v,ctx)
      elsif ctx && ctx[:kind]==:hip_soffit_height
        update_hip_soffit_height(x,y,v,ctx)
      elsif ctx && ctx[:kind]==:hip_fascia
        update_hip_fascia(x,y,v,ctx)
      elsif ctx && ctx[:kind]==:hip_pitch
        update_hip_pitch(x,y,v,ctx)
      elsif ctx && ctx[:kind]==:hip_ridge_height
        update_hip_ridge_height(x,y,v,ctx)
      elsif ctx && ctx[:kind]==:hip_ridge_length
        update_hip_ridge_length(x,y,v,ctx)
      else
        super
      end
    end

    def finish_drag
      kind=@drag_context ? @drag_context[:kind] : nil
      super
      if kind==:floor
        Sketchup.status_text='HIP v2.2.9 · Floor adjusted.'
      elsif kind==:wall
        Sketchup.status_text='HIP v2.2.9 · Wall resize complete. Ridge follows front/back length changes.'
      end
    end

    private

    def prepare_hip_length_ridge
      ctx=@drag_context
      ridge_ctx=find_edge_context('ridge')
      return unless ridge_ctx && ridge_ctx[:entities]==ctx[:entities]
      axis=ctx[:axis_local]; sel=ctx[:selected_plane]
      a=ridge_ctx[:edge].start; b=ridge_ctx[:edge].end
      pa=ctx[:original_positions][a] || a.position
      pb=ctx[:original_positions][b] || b.position
      da=(pa.vector_to(ORIGIN).reverse.dot(axis)-sel).abs
      db=(pb.vector_to(ORIGIN).reverse.dot(axis)-sel).abs
      ctx[:hip_length_ridge]=true
      moving=(da<=db ? a : b)
      fixed=(moving.equal?(a) ? b : a)
      ctx[:hip_moving_ridge_vertex]=moving
      ctx[:hip_fixed_ridge_vertex]=fixed

      # Store the signed ridge interval at drag start. The moving endpoint may
      # approach the fixed endpoint exactly, but can never cross it.
      mp=ctx[:original_positions][moving] || moving.position
      fp=ctx[:original_positions][fixed] || fixed.position
      ctx[:hip_ridge_moving_scalar]=mp.vector_to(ORIGIN).reverse.dot(axis)
      ctx[:hip_ridge_fixed_scalar]=fp.vector_to(ORIGIN).reverse.dot(axis)
    rescue => e
      puts "HIP ridge-follow preparation error: #{e.message}"
    end

    def find_all_edge_contexts(role)
      results=[]
      walk = lambda do |entities, tr|
        entities.each do |e|
          if e.is_a?(Sketchup::Edge)
            if e.get_attribute(Gablehip::ATTR_DICT,'role')==role
              results << {edge:e, entities:entities, local_to_world:tr}
            end
          elsif e.is_a?(Sketchup::Group)
            walk.call(e.entities, tr * e.transformation)
          elsif e.is_a?(Sketchup::ComponentInstance)
            walk.call(e.definition.entities, tr * e.transformation)
          end
        end
      end
      walk.call(@root.definition.entities, @root.transformation)
      results
    end

    def hip_role_vertices(roles)
      vertices=[]
      roles.each do |role|
        find_all_face_contexts(role).each do |c|
          c[:face].vertices.each{|vv| vertices << vv}
        end
        find_all_edge_contexts(role).each do |c|
          vertices << c[:edge].start << c[:edge].end
        end
      end
      vertices.uniq
    end

    def hip_vertical_mouse_parameter(x,y,view,ctx)
      origin=ctx[:origin_world]
      axis=ctx[:axis_world]
      p0=view.screen_coords(origin)
      p1=view.screen_coords(origin.offset(axis,100.0))
      dx=p1.x-p0.x
      dy=p1.y-p0.y
      denom=dx*dx+dy*dy
      return 0.0 if denom < 1.0e-9
      ((x-p0.x)*dx + (y-p0.y)*dy) / denom * 100.0
    end

    def hip_axis_mouse_parameter(x,y,view,ctx)
      origin=ctx[:origin_world]
      axis=ctx[:axis_world]
      p0=view.screen_coords(origin)
      p1=view.screen_coords(origin.offset(axis,100.0))
      dx=p1.x-p0.x
      dy=p1.y-p0.y
      denom=dx*dx+dy*dy
      return 0.0 if denom < 1.0e-9
      ((x-p0.x)*dx + (y-p0.y)*dy) / denom * 100.0
    end

    def start_hip_ridge_length_drag(role,x,y,v,flags=0)
      ridge_ctx=find_all_edge_contexts('ridge').first
      unless ridge_ctx
        UI.beep
        Sketchup.status_text='Hip ridge length: ridge edge not found.'
        return
      end

      ents=ridge_ctx[:entities]
      ridge=ridge_ctx[:edge]
      a=ridge.start
      b=ridge.end
      pa=a.position
      pb=b.position
      axis_local=pa.vector_to(pb)
      length=axis_local.length
      if length < PYRAMID_RIDGE_EPSILON
        UI.beep
        Sketchup.status_text='Hip ridge length: ridge is too short to resolve its axis.'
        return
      end
      axis_local.normalize!

      # Keep the ridge center fixed. Front/Back roof controls change only ridge
      # length: both endpoints travel equal/opposite distances.
      center_local=Geom::Point3d.new(
        (pa.x+pb.x)*0.5,(pa.y+pb.y)*0.5,(pa.z+pb.z)*0.5
      )

      # The clicked Front/Back face decides which end follows the cursor.
      face_ctx=find_all_face_contexts(role).first
      face_center=face_ctx ? face_ctx[:face].bounds.center : center_local
      da=face_center.distance(pa)
      db=face_center.distance(pb)
      grabbed=(da <= db ? a : b)
      other=(grabbed.equal?(a) ? b : a)
      grabbed_sign=(center_local.vector_to(grabbed.position).dot(axis_local) < 0.0 ? -1.0 : 1.0)
      asymmetric=((flags & CONSTRAIN_MODIFIER_MASK) != 0)

      axis_world=axis_local.transform(ridge_ctx[:local_to_world])
      axis_world.normalize!

      @dragging=true
      @hover_role=role
      @drag_context={
        kind: :hip_ridge_length, role:role, entities:ents,
        ridge_start:a, ridge_end:b,
        original_a:pa.clone, original_b:pb.clone,
        center_local:center_local,
        axis_local:axis_local, axis_world:axis_world,
        origin_world:grabbed.position.transform(ridge_ctx[:local_to_world]),
        grabbed:grabbed, other:other, grabbed_sign:grabbed_sign,
        asymmetric:asymmetric,
        start_parameter:nil, current_delta_local:0.0,
        original_length:length,
        min_length:PYRAMID_RIDGE_EPSILON,
        max_length:nil,
        source_roof_face:(face_ctx ? face_ctx[:face] : nil),
        source_roof_tr:(face_ctx ? face_ctx[:local_to_world] : nil)
      }

      # Maximum ridge = the symmetric distance available to the two end eave
      # planes along the ridge axis. At this point the end roof is visually
      # straight; extending farther would invert/overrun the Hip geometry.
      roof_vertices=hip_role_vertices(HIP_ROOFS + HIP_FASCIAS)
      projections=roof_vertices.map do |vv|
        Geom::Vector3d.new(vv.position.x-center_local.x,
                           vv.position.y-center_local.y,
                           vv.position.z-center_local.z).dot(axis_local)
      end
      unless projections.empty?
        negative=projections.select{|q|q < 0.0}.map(&:abs).max
        positive=projections.select{|q|q > 0.0}.max
        if negative && positive
          max_len=2.0 * [negative,positive].min - PYRAMID_RIDGE_EPSILON
          @drag_context[:max_length]=[max_len,PYRAMID_RIDGE_EPSILON].max
        end
      end
      if asymmetric
        # One-sided outward limit: use the farthest existing roof/fascia extent
        # on the selected side. Unlike the symmetric max_length, this does not
        # force the moving end to remain mirrored around the original center.
        cscalar=Geom::Vector3d.new(center_local.x,center_local.y,center_local.z).dot(axis_local)
        side_projections=roof_vertices.map do |vv|
          Geom::Vector3d.new(vv.position.x,vv.position.y,vv.position.z).dot(axis_local)
        end.select do |q|
          grabbed_sign < 0.0 ? q < cscalar : q > cscalar
        end
        unless side_projections.empty?
          @drag_context[:asym_side_limit_scalar] =
            grabbed_sign < 0.0 ? side_projections.min : side_projections.max
        end
      end

      @drag_context[:start_parameter]=hip_axis_mouse_parameter(x,y,v,@drag_context)
      Sketchup.active_model.start_operation(
        asymmetric ? 'Adjust Hip ridge length asymmetrically' : 'Adjust Hip ridge length',
        true
      )
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text = asymmetric ?
        'HIP RIDGE LENGTH · SHIFT asymmetric: only the clicked Front/Back end moves.' :
        'HIP RIDGE LENGTH · Front/Back roofs change ridge symmetrically. SHIFT = clicked end only.'
    rescue => e
      cancel_drag
      UI.messagebox("Hip ridge length error:\n#{e.message}")
    end

    # v2.2.5: Front/Back roof PLANE MATCH.
    # User drags a Hip end roof over another sloped roof face. The correct
    # result is not merely equal pitch: the moving ridge endpoint must land on
    # the target roof plane so both roof surfaces become continuous/coplanar.
    # The existing ridge-length manipulator remains the only deformation.
    def hip_roof_plane_match(x,y,v,ctx)
      ph=v.pick_helper
      ph.do_pick(x,y)

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

        n=face.normal.transform(tr)
        next if n.length<1.0e-9
        n.normalize!
        # Require a genuinely inclined target roof, not floor/wall.
        next if n.z.abs<1.0e-5 || n.z.abs>0.999999

        p0=face.vertices.first.position.transform(tr)
        axis=ctx[:axis_world].clone
        next if axis.length<1.0e-9
        axis.normalize!

        # Existing Front/Back control moves the grabbed ridge endpoint along
        # the ridge axis, with the opposite endpoint mirrored about the center.
        anchor=ctx[:origin_world]
        denom=axis.dot(n)
        next if denom.abs<1.0e-8

        # Intersection of the grabbed ridge endpoint's allowed movement line
        # with the target roof plane. This is the exact coplanar condition.
        distance=anchor.vector_to(p0).dot(n)/denom
        target=anchor.offset(axis,distance)

        center_world=ctx[:center_local].transform(ctx[:source_roof_tr])
        scalar=center_world.vector_to(target).dot(axis)
        half=scalar.abs
        next unless half.finite?

        @snap_target_face=face
        @snap_target_tr=tr
        @snap_target_role=entity_role(face)
        @snap_point_world=target
        @snap_label='SNAP: MATCH ROOF PLANE'
        v.tooltip=@snap_label rescue nil
        return half
      end

      @snap_target_face=nil
      @snap_target_tr=nil
      @snap_target_role=nil
      @snap_point_world=nil
      @snap_label=nil
      nil
    rescue => e
      puts "HIP roof plane-match snap error: #{e.message}"
      nil
    end

    def update_hip_ridge_length(x,y,v,ctx)
      raw=hip_axis_mouse_parameter(x,y,v,ctx)-ctx[:start_parameter]
      axis=ctx[:axis_local]

      if ctx[:asymmetric]
        # SHIFT: only the endpoint under the clicked Front/Back roof moves.
        # The opposite ridge endpoint is frozen exactly at its drag-start position.
        grabbed=ctx[:grabbed]
        fixed=ctx[:other]
        g0=(grabbed.equal?(ctx[:ridge_start]) ? ctx[:original_a] : ctx[:original_b])
        f0=(fixed.equal?(ctx[:ridge_start]) ? ctx[:original_a] : ctx[:original_b])

        # SHIFT asymmetric drag is anchored to the exact endpoint at mouse-down.
        # raw is already the cursor displacement along the ridge axis, so it
        # must be applied exactly once. Zero mouse motion = zero geometry motion.
        target=g0.offset(axis, raw)

        # Never allow the moving endpoint to cross the fixed endpoint.
        fixed_scalar=Geom::Vector3d.new(f0.x,f0.y,f0.z).dot(axis)
        target_scalar=Geom::Vector3d.new(target.x,target.y,target.z).dot(axis)
        min_sep=ctx[:min_length]
        if ctx[:grabbed_sign] < 0.0
          limit=fixed_scalar-min_sep
          if target_scalar > limit
            target=f0.offset(axis.reverse,min_sep)
            Sketchup.status_text='HIP ASYMMETRY LIMIT · Topology-safe pyramid reached.'
          end
        else
          limit=fixed_scalar+min_sep
          if target_scalar < limit
            target=f0.offset(axis,min_sep)
            Sketchup.status_text='HIP ASYMMETRY LIMIT · Topology-safe pyramid reached.'
          end
        end

        # One-sided outward guard. Use the actual roof/fascia extent on the
        # selected side, not the symmetric ridge envelope. This lets one SHIFT
        # drag travel the full valid range without stopping early/re-grabbing.
        if ctx[:asym_side_limit_scalar]
          tscalar=Geom::Vector3d.new(target.x,target.y,target.z).dot(axis)
          side_limit=ctx[:asym_side_limit_scalar]
          if (ctx[:grabbed_sign] < 0.0 && tscalar < side_limit) ||
             (ctx[:grabbed_sign] > 0.0 && tscalar > side_limit)
            current_scalar=Geom::Vector3d.new(g0.x,g0.y,g0.z).dot(axis)
            target=g0.offset(axis,side_limit-current_scalar)
            Sketchup.status_text='HIP ASYMMETRY LIMIT · Selected-side straight roof limit reached.'
          end
        end

        delta=grabbed.position.vector_to(target)
        unless delta.length < 1.0e-9
          ctx[:entities].transform_by_vectors([grabbed],[delta])
        end
        ctx[:current_delta_local]=raw
      else
        # Original frozen symmetric behavior.
        half0=ctx[:original_length]*0.5
        half=half0 + raw*ctx[:grabbed_sign]

        matched_half=hip_roof_plane_match(x,y,v,ctx)
        half=matched_half if matched_half

        min_half=ctx[:min_length]*0.5
        if half < min_half
          half=min_half
          Sketchup.status_text='HIP RIDGE LENGTH LIMIT · Topology-safe pyramid reached.'
        end

        if ctx[:max_length]
          max_half=ctx[:max_length]*0.5
          if half > max_half
            half=max_half
            Sketchup.status_text='HIP RIDGE LENGTH LIMIT · Straight roof limit reached.'
          end
        end

        c=ctx[:center_local]
        va=Geom::Vector3d.new(axis.x*half,axis.y*half,axis.z*half)
        target_a=c.offset(va.reverse)
        target_b=c.offset(va)

        moved=[]
        vectors=[]
        [[ctx[:ridge_start],target_a],[ctx[:ridge_end],target_b]].each do |vv,target|
          delta=vv.position.vector_to(target)
          next if delta.length < 1.0e-9
          moved << vv
          vectors << delta
        end
        ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
        ctx[:current_delta_local]=half-half0
      end

      rebuild_draw_items
    rescue => e
      puts "HIP ridge length update error: #{e.message}"
    end

    def start_hip_pitch_drag(role,x,y,v)
      ridge_ctx=find_all_edge_contexts('ridge').first
      unless ridge_ctx
        UI.beep
        Sketchup.status_text='Hip pitch: ridge edge not found.'
        return
      end
      ents=ridge_ctx[:entities]
      ridge_edge=ridge_ctx[:edge]
      r0=ridge_edge.start.position
      r1=ridge_edge.end.position
      ridge_z=(r0.z+r1.z)*0.5

      # True Hip pitch control: ridge remains fixed. The complete eave
      # perimeter rises/falls together, and roof vertices interpolate between
      # the fixed ridge and that moving perimeter.
      # Soffits are explicitly excluded from Pitch deformation. They must
      # remain rigid/horizontal; their dedicated Soffit Height control is the
      # only control allowed to translate them vertically.
      roles=(HIP_ROOFS + HIP_PITCHES + HIP_FASCIAS).uniq
      moving=hip_role_vertices(roles)

      soffit_vertices=hip_role_vertices(HIP_SOFFITS)
      moving.reject!{|vv| soffit_vertices.include?(vv)}
      original={}
      moving.each{|vv| original[vv]=vv.position.clone}

      # Soffits follow Pitch as rigid horizontal slabs. Cache them separately:
      # every soffit vertex receives the SAME Z delta, so neither the wall-side
      # nor outer edge can tilt relative to the other.
      soffit_original={}
      soffit_vertices.each{|vv| soffit_original[vv]=vv.position.clone}

      xs=original.values.map(&:x)
      ys=original.values.map(&:y)
      minx,maxx=xs.min,xs.max
      miny,maxy=ys.min,ys.max

      ridge_along_y=(r1.y-r0.y).abs >= (r1.x-r0.x).abs
      if ridge_along_y
        ridge_cross=(r0.x+r1.x)*0.5
        ridge_lo=[r0.y,r1.y].min
        ridge_hi=[r0.y,r1.y].max
        neg_span=[ridge_cross-minx,0.01.inch].max
        pos_span=[maxx-ridge_cross,0.01.inch].max
        lo_span=[ridge_lo-miny,0.01.inch].max
        hi_span=[maxy-ridge_hi,0.01.inch].max
      else
        ridge_cross=(r0.y+r1.y)*0.5
        ridge_lo=[r0.x,r1.x].min
        ridge_hi=[r0.x,r1.x].max
        neg_span=[ridge_cross-miny,0.01.inch].max
        pos_span=[maxy-ridge_cross,0.01.inch].max
        lo_span=[ridge_lo-minx,0.01.inch].max
        hi_span=[maxx-ridge_hi,0.01.inch].max
      end

      factors={}
      original.each do |vv,p0|
        if ridge_along_y
          lateral = p0.x <= ridge_cross ? (ridge_cross-p0.x)/neg_span : (p0.x-ridge_cross)/pos_span
          longitudinal =
            if p0.y < ridge_lo
              (ridge_lo-p0.y)/lo_span
            elsif p0.y > ridge_hi
              (p0.y-ridge_hi)/hi_span
            else
              0.0
            end
        else
          lateral = p0.y <= ridge_cross ? (ridge_cross-p0.y)/neg_span : (p0.y-ridge_cross)/pos_span
          longitudinal =
            if p0.x < ridge_lo
              (ridge_lo-p0.x)/lo_span
            elsif p0.x > ridge_hi
              (p0.x-ridge_hi)/hi_span
            else
              0.0
            end
        end
        f=[lateral,longitudinal].max
        f=0.0 if f < 0.0
        f=1.0 if f > 1.0
        # Ridge endpoints/topology stay mathematically fixed.
        f=0.0 if vv.equal?(ridge_edge.start) || vv.equal?(ridge_edge.end)
        factors[vv]=f
      end

      if original.empty?
        UI.beep
        Sketchup.status_text='Hip pitch: no movable roof/eave vertices found.'
        return
      end

      z_values=original.values.map{|pt| pt.z}.compact
      perimeter_candidates=[]
      original.each do |vv,p0|
        perimeter_candidates << p0.z if (factors[vv] || 0.0) >= 0.999
      end
      perimeter_z=perimeter_candidates.compact.max
      perimeter_z=z_values.min if perimeter_z.nil?
      raise 'Unable to resolve Hip pitch perimeter height.' if perimeter_z.nil?

      flat_gap=0.01.inch
      max_up=(ridge_z-flat_gap)-perimeter_z

      # Downward guard: use a tagged floor only when it yields a valid point.
      floor_ctx=find_all_face_contexts('floor').first
      floor_z=nil
      if floor_ctx && floor_ctx[:face] && floor_ctx[:face].valid?
        floor_vertices=floor_ctx[:face].vertices
        floor_z=floor_vertices.map{|fv|fv.position.z}.compact.max unless floor_vertices.empty?
      end
      floor_z=z_values.min if floor_z.nil?

      # Lower Pitch limit must follow the rigid soffits, not an arbitrary roof
      # perimeter Z. The lowest soffit vertex is the controlling geometry:
      # stop it just above the floor so the complete eave assembly can never
      # continue downward through the house.
      soffit_z_values=soffit_original.values.map{|pt|pt.z}.compact
      soffit_low_z=soffit_z_values.min
      controlling_low_z=soffit_low_z || perimeter_z
      min_down=(floor_z+0.05.inch)-controlling_low_z

      center=ridge_edge.bounds.center
      pitch_ctx=find_all_edge_contexts(role).first
      pitch_anchor_world=nil
      if pitch_ctx
        pe=pitch_ctx[:edge]
        pm=Geom.linear_combination(0.5,pe.start.position,0.5,pe.end.position)
        pitch_anchor_world=pm.transform(pitch_ctx[:local_to_world])
      end
      @dragging=true
      @drag_context={
        kind: :hip_pitch, role:role, entities:ents, vertices:moving,
        original_positions:original, factors:factors,
        soffit_vertices:soffit_vertices, soffit_original:soffit_original,
        axis_local:Geom::Vector3d.new(0,0,1),
        axis_world:Geom::Vector3d.new(0,0,1).transform(ridge_ctx[:local_to_world]),
        origin_world:center.transform(ridge_ctx[:local_to_world]),
        snap_anchor_world:(pitch_anchor_world || center.transform(ridge_ctx[:local_to_world])),
        start_parameter:nil,current_delta_local:0.0,
        max_up:max_up,min_down:min_down
      }
      @drag_context[:axis_world].normalize!
      @drag_context[:start_parameter]=hip_vertical_mouse_parameter(x,y,v,@drag_context)
      Sketchup.active_model.start_operation('Adjust Hip pitch',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='HIP PITCH · 4 eaves move together; ridge stays fixed.'
    rescue => e
      cancel_drag
      UI.messagebox("Hip pitch error:\n#{e.message}")
    end

    # v2.2.9: vertical inference snap for Hip Pitch / Ridge.
    # Priority is intentional: vertex -> edge/line -> face.
    # This lets a Hip pitch match another Gable/Hip pitch edge and lets the
    # Hip ridge match another ridge edge by HEIGHT, instead of being captured
    # first by a nearby roof face.
    def hip_vertical_geometry_snap(x,y,v,ctx,label)
      ph=v.pick_helper
      ph.do_pick(x,y)

      candidates=[]
      ph.count.times do |i|
        path=ph.path_at(i)
        next unless path
        next if path.include?(@root)

        tr=Geom::Transformation.new
        path.each do |node|
          if node.is_a?(Sketchup::Group) || node.is_a?(Sketchup::ComponentInstance)
            tr=tr*node.transformation
          end
        end

        leaf=path.last
        edge=path.reverse.find{|node| node.is_a?(Sketchup::Edge)}
        face=path.reverse.find{|node| node.is_a?(Sketchup::Face)}

        # Prefer explicit edge geometry. For height matching, the point on the
        # edge closest to the mouse is ideal; InputPoint gives SketchUp's own
        # inference position when available.
        if edge && edge.valid?
          etr=Geom::Transformation.new
          path.each do |node|
            if node.is_a?(Sketchup::Group) || node.is_a?(Sketchup::ComponentInstance)
              etr=etr*node.transformation
            end
            break if node.equal?(edge)
          end
          a=edge.start.position.transform(etr)
          b=edge.end.position.transform(etr)
          candidates << [:edge, edge, etr, a, b]
          next
        end

        if face && face.valid?
          ftr=Geom::Transformation.new
          path.each do |node|
            if node.is_a?(Sketchup::Group) || node.is_a?(Sketchup::ComponentInstance)
              ftr=ftr*node.transformation
            end
            break if node.equal?(face)
          end
          candidates << [:face, face, ftr]
        end
      end

      anchor=ctx[:snap_anchor_world] || ctx[:origin_world]
      axis=ctx[:axis_world].clone
      return nil if axis.length<1.0e-9
      axis.normalize!

      # 1) SketchUp inference point, but only when it resolves to external
      # vertex/edge geometry. This supports endpoints and arbitrary edge points.
      ip=Sketchup::InputPoint.new
      ip.pick(v,x,y)
      if ip.valid?
        begin
          if ip.vertex || ip.edge
            external=true
            ph.count.times do |i|
              path=ph.path_at(i)
              external=false if path && path.include?(@root)
            end
            if external
              target=ip.position
              dz=anchor.vector_to(target).dot(axis)
              @snap_point_world=target.clone
              @snap_label="#{label}: LINE"
              @snap_target_face=nil
              @snap_target_tr=nil
              @snap_target_role=nil
              v.tooltip=@snap_label rescue nil
              return dz
            end
          end
        rescue
        end
      end

      # 2) Edge fallback. Match the edge's HEIGHT. Horizontal ridge edges thus
      # snap exactly to ridge level; sloped pitch edges use the point nearest
      # the cursor in screen space via InputPoint when available, otherwise
      # their midpoint.
      edge_candidate=candidates.find{|c|c[0]==:edge}
      if edge_candidate
        edge=edge_candidate[1]
        etr=edge_candidate[2]
        a=edge_candidate[3]
        b=edge_candidate[4]
        target=Geom.linear_combination(0.5,a,0.5,b)
        dz=anchor.vector_to(target).dot(axis)
        @snap_point_world=target
        @snap_label="#{label}: LINE"
        @snap_target_face=nil
        @snap_target_tr=etr
        @snap_target_role=entity_role(edge)
        v.tooltip=@snap_label rescue nil
        return dz
      end

      # 3) Face fallback remains useful, but only after line inference failed.
      face_candidate=candidates.find{|c|c[0]==:face}
      if face_candidate
        face=face_candidate[1]
        ftr=face_candidate[2]
        p0=face.vertices.first.position.transform(ftr)
        n=face.normal.transform(ftr)
        if n.length>1.0e-9
          n.normalize!
          denom=axis.dot(n)
          if denom.abs>1.0e-8
            distance=anchor.vector_to(p0).dot(n)/denom
            target=anchor.offset(axis,distance)
            dz=anchor.vector_to(target).dot(axis)
            @snap_target_face=face
            @snap_target_tr=ftr
            @snap_target_role=entity_role(face)
            @snap_point_world=target
            @snap_label="#{label}: FACE"
            v.tooltip=@snap_label rescue nil
            return dz
          end
        end
      end

      @snap_target_face=nil
      @snap_target_tr=nil
      @snap_target_role=nil
      @snap_point_world=nil
      @snap_label=nil
      nil
    rescue => e
      puts "HIP vertical geometry snap error: #{e.message}"
      nil
    end

    def update_hip_pitch(x,y,v,ctx)
      dz=hip_vertical_mouse_parameter(x,y,v,ctx)-ctx[:start_parameter]
      snapped_dz=hip_vertical_geometry_snap(x,y,v,ctx,'SNAP: HIP PITCH')
      dz=snapped_dz unless snapped_dz.nil?
      if dz > ctx[:max_up]
        dz=ctx[:max_up]
        Sketchup.status_text='HIP PITCH LIMIT · Roof is visually flat; topology preserved.'
      elsif dz < ctx[:min_down]
        dz=ctx[:min_down]
        Sketchup.status_text='HIP PITCH LIMIT · Floor safety reached.'
      end

      moved=[]; vectors=[]
      ctx[:vertices].each do |vv|
        o=ctx[:original_positions][vv]
        next unless o
        factor=ctx[:factors][vv] || 0.0
        target=Geom::Point3d.new(o.x,o.y,o.z + dz*factor)
        delta=vv.position.vector_to(target)
        next if delta.length < 1.0e-9
        moved << vv
        vectors << delta
      end
      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?

      # Move all four soffits by the full Pitch delta as rigid bodies. Use the
      # drag-start positions every frame to preserve absolute/no-drift motion.
      soffit_moved=[]; soffit_vectors=[]
      (ctx[:soffit_vertices] || []).each do |vv|
        o=ctx[:soffit_original][vv]
        next unless o
        target=Geom::Point3d.new(o.x,o.y,o.z+dz)
        delta=vv.position.vector_to(target)
        next if delta.length < 1.0e-9
        soffit_moved << vv
        soffit_vectors << delta
      end
      ctx[:entities].transform_by_vectors(soffit_moved,soffit_vectors) unless soffit_moved.empty?

      ctx[:current_delta_local]=dz
      rebuild_draw_items
    rescue => e
      puts "HIP pitch update error: #{e.message}"
    end

    def start_hip_ridge_height_drag(x,y,v)
      ridge_ctx=find_all_edge_contexts('ridge').first
      return UI.beep unless ridge_ctx
      ents=ridge_ctx[:entities]
      ridge_vertices=[ridge_ctx[:edge].start,ridge_ctx[:edge].end]
      original={}
      ridge_vertices.each{|vv| original[vv]=vv.position.clone}

      # Moving the ridge changes the four connected roof planes while the
      # complete eave perimeter remains anchored.
      eave_vertices=hip_role_vertices(HIP_FASCIAS + HIP_SOFFITS)
      eave_z=eave_vertices.map{|vv|vv.position.z}.max
      ridge_z=ridge_vertices.map{|vv|vv.position.z}.sum/ridge_vertices.length.to_f
      center=ridge_ctx[:edge].bounds.center

      @dragging=true
      @drag_context={
        kind: :hip_ridge_height, entities:ents, vertices:ridge_vertices,
        original_positions:original,
        axis_local:Geom::Vector3d.new(0,0,1),
        axis_world:Geom::Vector3d.new(0,0,1).transform(ridge_ctx[:local_to_world]),
        origin_world:center.transform(ridge_ctx[:local_to_world]),
        start_parameter:nil,current_delta_local:0.0,
        ridge_z:ridge_z,eave_z:eave_z,min_gap:0.01.inch
      }
      @drag_context[:axis_world].normalize!
      @drag_context[:start_parameter]=hip_vertical_mouse_parameter(x,y,v,@drag_context)
      Sketchup.active_model.start_operation('Adjust Hip ridge height',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='HIP RIDGE · Vertical ridge height.'
    rescue => e
      cancel_drag
      UI.messagebox("Hip ridge error:\n#{e.message}")
    end

    def update_hip_ridge_height(x,y,v,ctx)
      dz=hip_vertical_mouse_parameter(x,y,v,ctx)-ctx[:start_parameter]
      snapped_dz=hip_vertical_geometry_snap(x,y,v,ctx,'SNAP: HIP RIDGE')
      dz=snapped_dz unless snapped_dz.nil?
      min_dz=(ctx[:eave_z]+ctx[:min_gap])-ctx[:ridge_z]
      if dz < min_dz
        dz=min_dz
        Sketchup.status_text='HIP RIDGE LIMIT · Minimum roof slope reached.'
      end
      moved=[]; vectors=[]
      ctx[:vertices].each do |vv|
        o=ctx[:original_positions][vv]
        target=Geom::Point3d.new(o.x,o.y,o.z+dz)
        delta=vv.position.vector_to(target)
        next if delta.length<1.0e-9
        moved << vv; vectors << delta
      end
      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
      ctx[:current_delta_local]=dz
      rebuild_draw_items
    rescue => e
      puts "HIP ridge update error: #{e.message}"
    end

    def start_hip_fascia_drag(role,x,y,v)
      fascia_contexts=HIP_FASCIAS.flat_map{|r| find_all_face_contexts(r)}
      if fascia_contexts.length < 4
        UI.beep
        Sketchup.status_text='Hip fascia: the four tagged fascia faces were not found.'
        return
      end

      first=fascia_contexts.first
      ents=first[:entities]
      local_to_world=first[:local_to_world]
      unless fascia_contexts.all?{|c|c[:entities]==ents}
        UI.beep
        Sketchup.status_text='Hip fascia: all four fascias must share one geometry context.'
        return
      end

      # The grabbed side only determines the mouse axis. Geometry is changed
      # symmetrically on all four sides.
      axis_local =
        case role
        when 'fascia_front','fascia_back' then Geom::Vector3d.new(0,1,0)
        else Geom::Vector3d.new(1,0,0)
        end

      grabbed=fascia_contexts.find{|c|c[:face].get_attribute(Gablehip::ATTR_DICT,'role')==role}
      return UI.beep unless grabbed
      center=grabbed[:face].bounds.center
      sign=(center.vector_to(ORIGIN).reverse.dot(axis_local) >= 0.0 ? 1.0 : -1.0)
      axis_local=axis_local.reverse if sign<0.0

      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      # Move the complete eave assembly: roof perimeter, all fascias and all
      # soffits. Ridge/pitch apex geometry is intentionally excluded.
      move_roles=(HIP_ROOFS + HIP_FASCIAS + HIP_SOFFITS).uniq
      vertices=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless erole && move_roles.include?(erole)
        case e
        when Sketchup::Face then e.vertices.each{|vv|vertices << vv}
        when Sketchup::Edge then vertices << e.start << e.end
        end
      end
      vertices.uniq!

      original_positions={}
      vertices.each{|vv|original_positions[vv]=vv.position.clone}

      # Determine original outer bounds. Each vertex moves only if it belongs
      # to an outer X/Y boundary; corner vertices therefore receive both axes.
      xs=original_positions.values.map(&:x); ys=original_positions.values.map(&:y)
      minx,maxx=xs.min,xs.max; miny,maxy=ys.min,ys.max
      tol=0.01.inch

      # Hard inward stop = wall footprint. This is topology-safe because the
      # fascia/eave perimeter may touch the wall planes, but opposite fascia
      # sides never cross each other.
      wall_centers={}
      WALL_ROLES.each do |wr|
        wc=find_all_face_contexts(wr).first
        wall_centers[wr]=wc[:face].bounds.center if wc && wc[:entities]==ents
      end
      wall_minx=[wall_centers['wall_left']&.x,wall_centers['wall_right']&.x].compact.min
      wall_maxx=[wall_centers['wall_left']&.x,wall_centers['wall_right']&.x].compact.max
      wall_miny=[wall_centers['wall_front']&.y,wall_centers['wall_back']&.y].compact.min
      wall_maxy=[wall_centers['wall_front']&.y,wall_centers['wall_back']&.y].compact.max

      @dragging=true
      @hover_role=role
      @drag_context={
        kind: :hip_fascia, role:role, entities:ents,
        vertices:vertices, original_positions:original_positions,
        axis_local:axis_local, axis_world:axis_world,
        origin_world:center.transform(local_to_world),
        local_to_world:local_to_world,
        minx:minx,maxx:maxx,miny:miny,maxy:maxy,
        wall_minx:wall_minx,wall_maxx:wall_maxx,
        wall_miny:wall_miny,wall_maxy:wall_maxy,
        tolerance:tol, start_parameter:nil,current_delta_local:0.0
      }
      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)
      Sketchup.active_model.start_operation('Adjust Hip fascias',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='HIP FASCIA · All 4 fascias expand/contract symmetrically.'
    rescue => e
      cancel_drag
      UI.messagebox("Hip fascia error:\n#{e.message}")
    end

    def update_hip_fascia(x,y,v,ctx)
      d=desired_local_from_mouse(x,y,v,ctx)

      # Convert grabbed-side outward motion into a universal perimeter delta.
      # Positive = expand; negative = contract.
      outward=d

      # Inward limit: each fascia may retract exactly to its corresponding
      # wall plane, never through it. Because all four move by one symmetric
      # perimeter delta, use the first wall contact among the four sides.
      inward_limits=[]
      # Keep a microscopic separation from the wall footprint. A true contact
      # can weld the eave vertices to the wall-top vertices in SketchUp; on the
      # next drag that merged vertex would pull the wall upward/outward with the
      # fascia. 0.01" is visually flush but preserves independent topology.
      eps=FASCIA_WALL_EPSILON
      inward_limits << (ctx[:wall_maxx] + eps - ctx[:maxx]) if ctx[:wall_maxx]
      inward_limits << (ctx[:minx] - eps - ctx[:wall_minx]) if ctx[:wall_minx]
      inward_limits << (ctx[:wall_maxy] + eps - ctx[:maxy]) if ctx[:wall_maxy]
      inward_limits << (ctx[:miny] - eps - ctx[:wall_miny]) if ctx[:wall_miny]
      lower=inward_limits.max
      if lower && outward < lower
        outward=lower
        Sketchup.status_text='HIP FASCIA LIMIT · Topology-safe wall limit reached.'
      end

      moved=[]; vectors=[]; tol=ctx[:tolerance]
      ctx[:vertices].each do |vv|
        o=ctx[:original_positions][vv]; next unless o
        tx=o.x; ty=o.y
        tx += outward if (o.x-ctx[:maxx]).abs<=tol
        tx -= outward if (o.x-ctx[:minx]).abs<=tol
        ty += outward if (o.y-ctx[:maxy]).abs<=tol
        ty -= outward if (o.y-ctx[:miny]).abs<=tol
        target=Geom::Point3d.new(tx,ty,o.z)
        delta=vv.position.vector_to(target)
        next if delta.length<1.0e-9
        moved << vv; vectors << delta
      end
      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
      ctx[:current_delta_local]=outward
      rebuild_draw_items
    rescue => e
      puts "HIP fascia update error: #{e.message}"
    end

    def start_hip_soffit_height_drag(x,y,v)
      soffit_contexts=HIP_SOFFITS.flat_map{|r| find_all_face_contexts(r)}
      if soffit_contexts.length < 4
        UI.beep
        Sketchup.status_text='Hip soffit height: the four tagged soffit faces were not found.'
        return
      end

      first=soffit_contexts.first
      ents=first[:entities]
      local_to_world=first[:local_to_world]
      unless soffit_contexts.all?{|c| c[:entities]==ents}
        UI.beep
        Sketchup.status_text='Hip soffit height: all four soffits must share one geometry context.'
        return
      end

      vertices=soffit_contexts.flat_map{|c|c[:face].vertices}.uniq
      original_positions={}
      vertices.each{|vv|original_positions[vv]=vv.position.clone}

      axis_local=Geom::Vector3d.new(0,0,1)
      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      pts=original_positions.values
      center_local=Geom::Point3d.new(
        pts.map(&:x).sum/pts.length.to_f,
        pts.map(&:y).sum/pts.length.to_f,
        pts.map(&:z).sum/pts.length.to_f
      )

      floor_ctx=find_face_context(FLOOR_ROLE)
      floor_z = floor_ctx && floor_ctx[:entities]==ents ?
        floor_ctx[:face].vertices.map{|vv|vv.position.z}.min : pts.map(&:z).min
      soffit_min_z=pts.map(&:z).min
      soffit_max_z=pts.map(&:z).max

      # v2.3.2: upper collision guard. Recompute it at EVERY drag start from
      # the current Hip geometry, including the pitch controls themselves.
      # A full 1-inch clearance is preserved so repeated release/re-grab cycles
      # can never accumulate through the roof/pitch topology.
      upper_candidates=[]
      (HIP_PITCHES + HIP_ROOFS + HIP_FASCIAS).uniq.each do |r|
        find_all_face_contexts(r).each do |c|
          next unless c[:entities]==ents
          c[:face].vertices.each{|vv| upper_candidates << vv.position.z}
        end
        find_all_edge_contexts(r).each do |c|
          next unless c[:entities]==ents
          upper_candidates << c[:edge].start.position.z << c[:edge].end.position.z
        end
      end
      upper_levels=upper_candidates.select{|z| z > soffit_max_z + 1.0e-6}
      upper_stop=upper_levels.min
      max_delta=upper_stop ? (upper_stop - 0.1.inch - soffit_max_z) : nil
      max_delta=0.0 if max_delta && max_delta < 0.0

      # Keep a small safety clearance above the floor.
      min_delta=(floor_z + 0.01.inch) - soffit_min_z

      @dragging=true
      @hover_role='soffit_front'
      @drag_context={
        kind: :hip_soffit_height,
        role:'soffit_front',
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:center_local.transform(local_to_world),
        local_to_world:local_to_world,
        min_delta:min_delta,
        max_delta:max_delta,
        start_parameter:nil,
        current_delta_local:0.0
      }
      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation('Adjust Hip soffit height',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='HIP SOFFIT HEIGHT · All 4 soffits move vertically together.'
    rescue => e
      cancel_drag
      UI.messagebox("Hip soffit height error:\n#{e.message}")
    end

    def update_hip_soffit_height(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)
      if ctx[:max_delta] && desired_local > ctx[:max_delta]
        desired_local=ctx[:max_delta]
        Sketchup.status_text='Hip soffit upper limit: 0.1-inch pitch/roof safety gap reached.'
      elsif desired_local < ctx[:min_delta]
        desired_local=ctx[:min_delta]
        Sketchup.status_text='Hip soffit lower limit reached.'
      end

      moved=[]; vectors=[]
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
      puts "HIP soffit height update error: #{e.message}"
    end

    def start_hip_roof_height_drag(x,y,v)
      roof_contexts=HIP_ROOFS.flat_map{|r| find_all_face_contexts(r)}
      if roof_contexts.length < 4
        UI.beep
        Sketchup.status_text='Hip roof height: the four tagged roof faces were not found.'
        return
      end

      first=roof_contexts.first
      ents=first[:entities]
      local_to_world=first[:local_to_world]
      unless roof_contexts.all?{|c| c[:entities]==ents}
        UI.beep
        Sketchup.status_text='Hip roof height: all four roof faces must share one geometry context.'
        return
      end

      axis_local=Geom::Vector3d.new(0,0,1)
      axis_world=axis_local.transform(local_to_world)
      axis_world.normalize!

      moving_roles=(HIP_ROOFS + HIP_SOFFITS + HIP_FASCIAS +
                    HIP_PITCHES + ['ridge']).uniq

      vertices=[]
      ents.each do |e|
        next unless e.respond_to?(:get_attribute)
        erole=e.get_attribute(Gablehip::ATTR_DICT,'role')
        next unless erole && moving_roles.include?(erole)
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
        Sketchup.status_text='Hip roof height: no roof assembly vertices found.'
        return
      end

      original_positions={}
      vertices.each{|vv| original_positions[vv]=vv.position.clone}

      floor_ctx=find_face_context(FLOOR_ROLE)
      house_base_z = floor_ctx && floor_ctx[:entities]==ents ?
        floor_ctx[:face].vertices.map{|vv|vv.position.z}.min :
        ents.to_a.select{|e|e.respond_to?(:bounds)}.map{|e|e.bounds.min.z}.min
      house_base_z ||= 0.0

      lowest_roof_z=roof_contexts.flat_map{|c|c[:face].vertices}.
        map{|vv| original_positions[vv] || vv.position}.map(&:z).min

      highest_z=original_positions.values.map(&:z).max
      house_height=[highest_z-house_base_z,1.inch].max
      floor_guard=[[house_height*0.02,6.inch].max,12.inch].min
      min_delta=(house_base_z+floor_guard)-lowest_roof_z

      roof_points=roof_contexts.flat_map{|c|c[:face].vertices.map(&:position)}
      center_local=Geom::Point3d.new(
        roof_points.map(&:x).sum/roof_points.length.to_f,
        roof_points.map(&:y).sum/roof_points.length.to_f,
        roof_points.map(&:z).sum/roof_points.length.to_f
      )

      @dragging=true
      @hover_role='roof_left'
      @drag_context={
        kind: :hip_roof_height,
        role:'roof_left',
        entities:ents,
        vertices:vertices,
        original_positions:original_positions,
        axis_local:axis_local,
        axis_world:axis_world,
        origin_world:center_local.transform(local_to_world),
        local_to_world:local_to_world,
        min_delta:min_delta,
        start_parameter:nil,
        current_delta_local:0.0
      }
      @drag_context[:start_parameter]=mouse_axis_parameter(x,y,v,@drag_context)

      Sketchup.active_model.start_operation('Adjust Hip roof height',true)
      @op_open=true
      rebuild_draw_items
      Sketchup.status_text='HIP ROOF HEIGHT · Drag up/down. All 4 waters move together; roof shape stays rigid.'
    rescue => e
      cancel_drag
      UI.messagebox("Hip roof height error:\n#{e.message}")
    end

    def update_hip_roof_height(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)
      if desired_local < ctx[:min_delta]
        desired_local=ctx[:min_delta]
        Sketchup.status_text='Hip roof lower limit reached.'
      end

      moved=[]; vectors=[]
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
      puts "HIP roof height update error: #{e.message}"
    end

    def update_hip_length_wall(x,y,v,ctx)
      desired_local=desired_local_from_mouse(x,y,v,ctx)

      # PERSISTENT PYRAMID LIMIT:
      # Determine which side this wall belongs to from the wall/opposite-wall
      # relationship, not from ridge length. Therefore the rule still has a
      # direction even when a new drag starts with both ridge endpoints already
      # coincident (ridge length == 0).
      rm=ctx[:hip_ridge_moving_scalar]
      rf=ctx[:hip_ridge_fixed_scalar]
      if rm && rf
        wall_sign=(ctx[:selected_plane]-ctx[:opposite_plane]) >= 0.0 ? 1.0 : -1.0
        requested_gap=(rm+desired_local)-rf

        # Never collapse the ridge to true zero: SketchUp may merge/coalesce the
        # coincident topology, making a later reopen produce crossed faces.
        # Clamp at a microscopic signed ridge length instead. Visually this is
        # still a pyramid, but both ridge endpoints remain distinct and the Hip
        # can reopen cleanly on a later drag.
        min_gap=PYRAMID_RIDGE_EPSILON * wall_sign
        if requested_gap * wall_sign < PYRAMID_RIDGE_EPSILON
          desired_local=(rf + min_gap) - rm
          Sketchup.status_text='HIP PYRAMID LIMIT · Topology-safe pyramid reached; reopening remains available.'
        end
      end

      if ctx[:opposite_plane] && ctx[:min_span]
        new_selected_plane=ctx[:selected_plane]+desired_local
        new_span=(new_selected_plane-ctx[:opposite_plane]).abs
        crossed=((ctx[:selected_plane]-ctx[:opposite_plane]) *
                 (new_selected_plane-ctx[:opposite_plane])) <= 0.0
        if crossed || new_span<=ctx[:min_span]
          role=ctx[:role]
          Sketchup.active_model.abort_operation if @op_open
          @op_open=false; @dragging=false; @drag_context=nil; @parallel_start_x=nil
          @hover_role=role; rebuild_draw_items
          UI.beep
          Sketchup.status_text='Safety limit reached: walls cannot cross. Geometry restored.'
          return
        end
      end

      axis=ctx[:axis_local]; sel=ctx[:selected_plane]; tol=ctx[:tolerance]
      ridge_vertex=ctx[:hip_moving_ridge_vertex]
      moved=[]; vectors=[]
      ctx[:vertices].each do |vv|
        original=ctx[:original_positions][vv]; next unless original
        p=original.vector_to(ORIGIN).reverse.dot(axis)
        factor=(p >= (sel-tol) || vv.equal?(ridge_vertex)) ? 1.0 : 0.0
        target=original.clone
        if factor>0.0
          offset=axis.clone; offset.length=desired_local
          target=original+offset
        end
        delta=vv.position.vector_to(target)
        next if delta.length<1.0e-9
        moved << vv; vectors << delta
      end
      ctx[:entities].transform_by_vectors(moved,vectors) unless moved.empty?
      ctx[:current_delta_local]=desired_local
      rebuild_draw_items
    rescue => e
      puts "HIP length wall update error: #{e.message}"
    end
  end
end
