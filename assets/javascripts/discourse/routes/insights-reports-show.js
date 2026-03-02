import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";

export default class InsightsReportsShowRoute extends DiscourseRoute {
  async model(params) {
    return await ajax(`/insights/shared-reports/${params.key}.json`);
  }
}
