export default function () {
  this.route("insights", function () {
    this.route("reports", function () {
      this.route("show", { path: "/:key" });
    });
  });
}
