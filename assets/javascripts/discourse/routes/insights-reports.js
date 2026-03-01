import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";

export default class InsightsReportsRoute extends DiscourseRoute {
  queryParams = {
    period: { refreshModel: false },
    start_date: { refreshModel: false },
    end_date: { refreshModel: false },
  };

  async model(params) {
    const result = await ajax("/insights/reports.json");
    return {
      reports: result.reports,
      period: params.period || "30d",
      start_date: params.start_date,
      end_date: params.end_date,
    };
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
