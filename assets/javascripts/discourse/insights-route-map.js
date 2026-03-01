export default function () {
  this.route("insights", function () {
    this.route("reports");
  });
}
