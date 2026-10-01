require 'sketchup.rb'
require_relative 'placement_tool'
require_relative 'semantic_drag_tool'
require_relative 'mode2_drag_tool'
require_relative 'mode3_drag_tool'
require_relative 'selection_observer'
require_relative 'duplicate_placement_tool'
require_relative 'hip_inspect_tool'
require_relative 'hip_drag_tool'
require_relative 'hip_placement_tool'

module Gablehip
  ATTR_DICT='ParametricGable'

  HIP_TEMPLATE=File.join(__dir__,'templates','hip','template.skp').freeze

  MODE_TEMPLATES={
    1=>File.join(__dir__,'templates','gable','flat_soffit','template.skp'),
    2=>File.join(__dir__,'templates','gable','pork_chop_eaves','template.skp'),
    3=>File.join(__dir__,'templates','gable','angled_soffit','template.skp')
  }.freeze

  def self.editable_instance?(e)
    e.is_a?(Sketchup::ComponentInstance) && %w[gable_roof hip_roof].include?(e.get_attribute(ATTR_DICT,'template'))
  end

  def self.place_mode(mode)
    mode=mode.to_i
    path=MODE_TEMPLATES[mode]
    unless path && File.exist?(path)
      UI.messagebox("Gable Mode #{mode} template not found:\n#{path}")
      return
    end
    Sketchup.active_model.select_tool(PlacementTool.new(path,mode))
  end

  def self.place_hip
    unless File.exist?(HIP_TEMPLATE)
      UI.messagebox("Hip template not found:\n#{HIP_TEMPLATE}")
      return
    end
    Sketchup.active_model.select_tool(HipPlacementTool.new(HIP_TEMPLATE))
  end

  def self.edit(instance)
    if instance.get_attribute(ATTR_DICT,'template')=='hip_roof'
      Sketchup.active_model.select_tool(HipDragTool.new(instance))
      return
    end
    mode=instance.get_attribute(ATTR_DICT,'mode',1).to_i
    tool =
      case mode
      when 2 then Mode2DragTool.new(instance)
      when 3 then Mode3DragTool.new(instance)
      else SemanticDragTool.new(instance)
      end
    Sketchup.active_model.select_tool(tool)
  end


  def self.duplicate_parametric(instance)
    return unless editable_instance?(instance) && instance.valid?
    Sketchup.active_model.select_tool(DuplicatePlacementTool.new(instance))
  end

  def self.install_context_menu
    return if @context_menu_installed
    UI.add_context_menu_handler do |menu|
      sel=Sketchup.active_model.selection
      next unless sel.length==1
      instance=sel.first
      next unless editable_instance?(instance)
      menu.add_separator
      label=instance.get_attribute(ATTR_DICT,'template')=='hip_roof' ? 'Duplicate Parametric Hip' : 'Duplicate Gablehip'
      menu.add_item(label){ duplicate_parametric(instance) }
    end
    @context_menu_installed=true
  end

  def self.ui_asset_url(filename)
    path=File.join(__dir__,'assets','ui',filename).tr('\\','/')
    "file:///#{path.gsub(' ','%20')}"
  end

  def self.selector_html
    gable=ui_asset_url('gable.png')
    hip=ui_asset_url('hip.png')
    mode1=ui_asset_url('flat_soffit.png')
    mode2=ui_asset_url('pork_chop_eaves.png')
    mode3=ui_asset_url('angled_soffit.png')
    <<~HTML
      <!doctype html>
      <html>
      <head>
        <meta charset="utf-8">
        <style>
          * { box-sizing:border-box; }
          body {
            margin:0; background:#f3f3f3; color:#222;
            font-family:Segoe UI, Arial, sans-serif;
            user-select:none; overflow:hidden;
          }
          .wrap { padding:20px; }
          .top { display:flex; align-items:center; justify-content:space-between; margin-bottom:16px; }
          .title { font-size:20px; font-weight:650; }
          .sub { color:#666; font-size:12px; margin-top:4px; }
          .back {
            display:none; border:1px solid #c9c9c9; background:#fff; color:#222;
            border-radius:6px; padding:7px 12px; cursor:pointer;
          }
          .back:hover { border-color:#2f7ed8; background:#eaf3ff; }
          .grid { display:grid; grid-template-columns:repeat(2,1fr); gap:14px; }
          .grid.modes { grid-template-columns:repeat(3,1fr); }
          .card {
            height:350px; background:#fff; border:1px solid #c9c9c9; border-radius:9px;
            padding:12px; cursor:pointer; transition:.12s ease;
            display:flex; flex-direction:column;
          }
          .grid.modes .card { height:350px; }
          .card:hover { border-color:#2f7ed8; background:#eaf3ff; transform:translateY(-1px); }
          .card.disabled { opacity:.45; cursor:default; }
          .card.disabled:hover { border-color:#c9c9c9; background:#fff; transform:none; }
          .image {
            flex:1; min-height:0; display:flex; align-items:center; justify-content:center;
            background:#fff; border-radius:5px; overflow:hidden; margin-bottom:10px;
          }
          .image img { width:100%; height:100%; object-fit:contain; display:block; }
          .name { font-weight:650; font-size:15px; }
          .desc { color:#666; font-size:11px; margin-top:4px; line-height:1.35; min-height:30px; }
          .tag {
            display:inline-block; align-self:flex-start; margin-top:8px; font-size:10px;
            padding:3px 7px; border-radius:999px; background:#e7e7e7; color:#555;
          }
          .hint { margin-top:14px; color:#777; font-size:10px; text-align:center; }
        </style>
      </head>
      <body>
        <div class="wrap">
          <div class="top">
            <div>
              <div class="title" id="title">Choose roof family</div>
              <div class="sub" id="sub">Select the roof type you want to place.</div>
            </div>
            <button class="back" id="back" onclick="showFamilies()">Back</button>
          </div>

          <div id="families" class="grid">
            <div class="card" onclick="showGables()">
              <div class="image"><img src="#{gable}" alt="Gable"></div>
              <div class="name">Gable</div>
              <div class="desc">Two-slope roof.</div>
              <span class="tag">3 styles</span>
            </div>
            <div class="card" onclick="placeHip()">
              <div class="image"><img src="#{hip}" alt="Hip"></div>
              <div class="name">Hip</div>
              <div class="desc">Four-slope roof.</div>
              <span class="tag">UNIQUE</span>
            </div>
          </div>

          <div id="gables" class="grid modes" style="display:none;">
            <div class="card" onclick="place(1)">
              <div class="image"><img src="#{mode1}" alt="Flat Soffit"></div>
              <div class="name">Flat Soffit</div>
              <div class="desc">Flat soffit configuration.</div>
            </div>
            <div class="card" onclick="place(2)">
              <div class="image"><img src="#{mode2}" alt="Pork Chop Eaves"></div>
              <div class="name">Pork Chop Eaves</div>
              <div class="desc">Pork chop eave configuration.</div>
            </div>
            <div class="card" onclick="place(3)">
              <div class="image"><img src="#{mode3}" alt="Angled Soffit"></div>
              <div class="name">Angled Soffit</div>
              <div class="desc">Soffit follows the roof slope.</div>
            </div>
          </div>

          <div class="hint">Selecting a style attaches that template to the cursor.</div>
        </div>
        <script>
          function showGables(){
            document.getElementById('families').style.display='none';
            document.getElementById('gables').style.display='grid';
            document.getElementById('back').style.display='block';
            document.getElementById('title').textContent='Choose Gable style';
            document.getElementById('sub').textContent='Select the soffit and eave configuration.';
          }
          function showFamilies(){
            document.getElementById('families').style.display='grid';
            document.getElementById('gables').style.display='none';
            document.getElementById('back').style.display='none';
            document.getElementById('title').textContent='Choose roof family';
            document.getElementById('sub').textContent='Select the roof type you want to place.';
          }
          function place(mode){ sketchup.place_mode(mode); }
          function placeHip(){ sketchup.place_hip(); }
        </script>
      </body>
      </html>
    HTML
  end

  def self.show_selector
    if defined?(@selector) && @selector && @selector.visible?
      @selector.bring_to_front
      return
    end

    @selector=UI::HtmlDialog.new(
      dialog_title:'Gablehip Generator',
      preferences_key:'Gablehip.Selector',
      scrollable:false,
      resizable:false,
      width:820,
      height:470,
      style:UI::HtmlDialog::STYLE_DIALOG
    )

    @selector.set_html(selector_html)
    @selector.add_action_callback('place_mode') do |_context,mode|
      @selector.close if @selector
      place_mode(mode)
    end
    @selector.add_action_callback('place_hip') do |_context|
      @selector.close if @selector
      place_hip
    end
    @selector.show
  end

  unless file_loaded?(__FILE__)
    cmd=UI::Command.new('Gablehip'){ show_selector }
    cmd.tooltip='Gablehip Generator'
    cmd.status_bar_text='Choose a roof family and style.'
    cmd.small_icon=File.join(__dir__,'assets','icons','plugin.svg')
    cmd.large_icon=File.join(__dir__,'assets','icons','plugin.svg')

    tb=UI::Toolbar.new('Gablehip')
    tb.add_item(cmd)
    tb.restore

    UI.menu('Extensions').add_item('Gablehip Generator...'){ show_selector }

    SelectionObserver.install
    install_context_menu
    file_loaded(__FILE__)
  end
end
