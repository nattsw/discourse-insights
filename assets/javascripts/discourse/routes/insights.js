import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class InsightsRoute extends DiscourseRoute {
  @service router;
  @service siteSettings;

  beforeModel() {
    if (!this.currentUser || !this.siteSettings.insights_enabled) {
      return this.router.replaceWith("discovery.latest");
    }
  }

  async model() {
    try {
      return await ajax("/insights/health.json", {
        data: { period: "30d" },
      });
    } catch {
      return { error: true };
    }
  }
}
