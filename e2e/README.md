# understanding-surfaces, end to end

`scripts/e2e/mentor-e2e run understanding-surfaces` on the branch: **pass** in 102s, replay only.

| check | result |
| --- | --- |
| the mentor call wrote an understanding=1 | pass |
| the menu shows the goal it worked out=yes | pass |
| the card shows the goal=yes | pass |
| the card names the refresh interval=yes | pass |
| the card offers Reset Understanding=yes | pass |
| Settings shows the current goal=yes | pass |
| the confirmation asks before resetting=yes | pass |
| the confirmation says it cannot be undone=yes | pass |
| the confirmation offers Cancel=yes | pass |
| Cancel keeps the understanding=1 | pass |
| Cancel journals no reset=0 | pass |
| Reset Understanding forgets every revision=0 | pass |
| the reset is journaled=1 | pass |
| the card says there is no understanding yet=yes | pass |
| the menu says the goal is not worked out yet=yes | pass |

Screenshots in this directory are the run's own: `card.png` (the card with the understanding the mentor
call wrote), `settings.png` (Settings > Models), `confirmation.png` (Reset the understanding?),
`card-after-reset.png`, and the menu before and after the reset. `run-log.txt` is the run's log.
