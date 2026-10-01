require 'sketchup.rb'
module Gablehip
  module SelectionObserver
    class Obs < Sketchup::SelectionObserver
      def onSelectionBulkChange(s); check(s); end
      def onSelectionAdded(s,e); check(s); end
      def check(s)
        return if SelectionObserver.suspended?
        return unless s.length==1
        e=s.first
        return unless Gablehip.editable_instance?(e)
        UI.start_timer(0,false){
          Gablehip.edit(e) if !SelectionObserver.suspended? && e.valid?
        }
      end
    end
    class AppObs < Sketchup::AppObserver
      def onNewModel(m); SelectionObserver.attach(m); end
      def onOpenModel(m); SelectionObserver.attach(m); end
    end
    module_function
    def install
      @obs ||= Obs.new; attach(Sketchup.active_model)
      @app ||= AppObs.new
      Sketchup.add_observer(@app) unless @app_added
      @app_added=true
    end
    def attach(m); m.selection.add_observer(@obs ||= Obs.new); rescue; end
    def suspend; @suspended=true; yield; ensure @suspended=false; end
    def suspended?; !!@suspended; end
  end
end
