const assert = require("node:assert/strict");
const flows = require("../node-red/flows.json");
const run = (id) => new Function("msg", flows.find((n) => n.id === id).func);
const inbound = run("4042c583.30152c"),
  outbound = run("809501fc.734ef");
for (const parameters of [
  [1],
  [180, 75],
  [],
  ["cue", "12", "Evening", "", "", false, 5000, -1],
]) {
  const msg = inbound({ payload: { address: "/eos/test", parameters } });
  assert.equal(msg.topic, "/eos/test");
  assert.deepEqual(
    msg.payload,
    parameters.length > 1 ? parameters : parameters.length ? parameters[0] : "",
  );
}
for (const payload of [
  1,
  "test",
  [180, 75],
  ["cue", "12", "Evening", "", "", false, 5000, -1],
]) {
  const msg = outbound({ topic: "/eos/out/test", payload });
  assert.deepEqual(
    msg.payload.parameters,
    Array.isArray(payload) ? payload : [payload],
  );
}
console.log(
  "PASS: bridge preserves scalar, empty, color and cue OSC arguments.",
);
