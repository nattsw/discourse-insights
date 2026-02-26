import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class InsightsRoute extends DiscourseRoute {
  @service router;
  @service siteSettings;

  queryParams = {
    period: { refreshModel: false },
    start_date: { refreshModel: false },
    end_date: { refreshModel: false },
  };

  beforeModel() {
    if (!this.currentUser || !this.siteSettings.insights_enabled) {
      return this.router.replaceWith("discovery.latest");
    }
  }

  async model(params) {
    const data = {};
    if (params.start_date && params.end_date) {
      data.start_date = params.start_date;
      data.end_date = params.end_date;
    } else {
      data.period = params.period || "30d";
    }

    try {
      return await ajax("/insights/health.json", { data });
    } catch {
      return { error: true };
    }
  }

  resetController(controller, isExiting) {
    if (isExiting) {
      controller.setProperties({
        period: null,
        start_date: null,
        end_date: null,
      });
    }
  }
}
