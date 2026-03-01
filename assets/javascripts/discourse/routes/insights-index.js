import DiscourseRoute from "discourse/routes/discourse";

export default class InsightsIndexRoute extends DiscourseRoute {
  queryParams = {
    period: { refreshModel: false },
    start_date: { refreshModel: false },
    end_date: { refreshModel: false },
  };

  model(params) {
    return {
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
