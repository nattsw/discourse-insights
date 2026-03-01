import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";

export default class InsightsIndexController extends Controller {
  @tracked end_date = null;
  @tracked period = null;
  @tracked start_date = null;

  queryParams = ["period", "start_date", "end_date"];
}
