This Lake package models `HeatGuardStep` from Glancebar’s `Sources/pure.m`, using integer tenths of a degree for battery temperature and the same idle / engaged / stood-down state machine as the app.

It proves safety properties of that step function: disabled guard never enables Low Power, disable and enable only occur in the expected states and temperature band, user Low Power override stands the guard down, and unread temperature never triggers enable (with a documented weaker form of “never acts” where the C code can still disable from engaged when the guard is turned off).

Check the proofs with: `cd proofs && ~/.elan/bin/lake build`.
