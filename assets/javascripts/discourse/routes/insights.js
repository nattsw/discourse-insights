import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";

export default class InsightsRoute extends DiscourseRoute {
  @service router;
  @service siteSettings;

  beforeModel() {
    if (!this.currentUser || !this.siteSettings.insights_enabled) {
      return this.router.replaceWith("discovery.latest");
    }
  }
}
