export default function secondFixtureExtension(pi) {
  pi.on("session_start", () => {
    pi.appendEntry("fixture-session-start", { entry: "secondary" });
  });
}
