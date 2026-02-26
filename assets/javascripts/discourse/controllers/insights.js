import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";

export default class InsightsController extends Controller {
  queryParams = ["period", "start_date", "end_date"];

  @tracked period = null;
  @tracked start_date = null;
  @tracked end_date = null;
}
