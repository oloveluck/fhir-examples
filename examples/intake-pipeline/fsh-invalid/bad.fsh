// An example meant to fail, kept apart so `raco fsh check .` stays a pass/fail gate:
//   raco fsh check fsh-invalid --context fsh
Instance: intake-bad
InstanceOf: IntakePatient
* name.family = "Nobody"
* gender = #male
