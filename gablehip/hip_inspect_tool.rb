require 'sketchup.rb'
module Gablehip
  class HipInspectTool
    PINK=Sketchup::Color.new(0,122,204,105); PINK_EDGE=Sketchup::Color.new(0,122,204)
    EXPECTED=%w[wall_front wall_back wall_left wall_right roof_front roof_back roof_left roof_right soffit_front soffit_back soffit_left soffit_right fascia_front fascia_back fascia_left fascia_right pitch_front pitch_back pitch_left pitch_right ridge floor].freeze
    def initialize(root); @root=root; @hover=nil; @hover_tr=Geom::Transformation.new; @role=nil; end
    def activate
      validate_roles
      Sketchup.status_text='HIP v2.0 · Hover verifies semantic controls. Geometry editing begins in the next Hip stage. Esc exits.'
    end
    def onMouseMove(_,x,y,v); pick(v,x,y); v.invalidate; end
    def onLButtonDown(_,x,y,v); pick(v,x,y); v.invalidate; end
    def onCancel(_,v); Sketchup.active_model.select_tool(nil); v.invalidate; end
    def draw(v)
      return unless @hover
      if @hover.is_a?(Sketchup::Face)
        tris=[]
        mesh=@hover.mesh(0)
        mesh.polygons.each do |poly|
          pts=poly.map{|idx| mesh.point_at(idx.abs).transform(@hover_tr)}
          tris << pts if pts.length>=3
        end
        v.drawing_color=PINK; tris.each{|pts|v.draw(GL_POLYGON,pts)}
        pts=@hover.outer_loop.vertices.map{|q|q.position.transform(@hover_tr)}
        v.drawing_color=PINK_EDGE; v.line_width=3; v.draw(GL_LINE_LOOP,pts); v.line_width=1
      else
        v.drawing_color=PINK_EDGE; v.line_width=7
        v.draw(GL_LINES,[@hover.start.position.transform(@hover_tr),@hover.end.position.transform(@hover_tr)]); v.line_width=1
      end
      v.draw_text([18,18],"HIP · #{@role}",size:13,bold:true,color:PINK_EDGE) if @role
    rescue => e
      puts "Hip inspect draw error: #{e.message}"
    end
    private
    def inside_root_path?(path)
      return false unless path && @root
      path.include?(@root) || path.first==@root
    end
    def pick(v,x,y)
      @hover=nil; @role=nil
      ph=v.pick_helper; ph.do_pick(x,y)
      ph.count.times do |i|
        path=ph.path_at(i); next unless path && inside_root_path?(path)
        e=path.last; next unless e.is_a?(Sketchup::Face)||e.is_a?(Sketchup::Edge)
        role=e.get_attribute(Gablehip::ATTR_DICT,'role'); next unless role && !role.empty?
        @hover=e; @role=role; @hover_tr=(ph.transformation_at(i) rescue @root.transformation); break
      end
      Sketchup.status_text=@role ? "HIP v2.0 · #{@role}" : 'HIP v2.0 · Hover a tagged Hip control.'
    end
    def collect_roles(ents,counts,depth=0)
      return if depth>30
      ents.each do |e|
        case e
        when Sketchup::Face,Sketchup::Edge
          r=e.get_attribute(Gablehip::ATTR_DICT,'role'); counts[r]+=1 if r && !r.empty?
        when Sketchup::Group then collect_roles(e.entities,counts,depth+1)
        when Sketchup::ComponentInstance then collect_roles(e.definition.entities,counts,depth+1)
        end
      end
    end
    def validate_roles
      counts=Hash.new(0); collect_roles(@root.definition.entities,counts)
      missing=EXPECTED.select{|r|counts[r]==0}
      puts "HIP v2.0 semantic roles: #{counts.sort.map{|k,n|"#{k}=#{n}"}.join(', ')}"
      UI.messagebox("HIP v2.0 template validation:\nMissing tags: #{missing.join(', ')}") unless missing.empty?
    end
  end
end
