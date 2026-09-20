# Taskwarrior Panel

A plugin for the noctalia desktop shell backed by Taskwarrior. It shows a pending count on the bar and offers a panel for quick capture and a read-only view of pending work. Triage beyond ticking, editing text, and deleting is deliberately left to the CLI.

## Language

**Task**:
A single Taskwarrior task. The plugin only ever reasons about pending ones.

**Capture**:
Writing down a task quickly before it is forgotten. The panel exists for this above all else; the capture box is always visible and focused.
_Avoid_: Add, create, insert

**Pending**:
A task not yet completed or deleted. What the bar count and the list show, minus waiting tasks (see Waiting).
_Avoid_: Open, active (Taskwarrior uses "active" for a started task)

**Waiting**:
A pending task deferred with `wait:`. Hidden from the panel and the bar count until the wait expires.
_Avoid_: Deferred, snoozed

**Urgency**:
The score Taskwarrior computes for a task from its attributes. The default sort order. Never editable.

**Priority**:
The optional H/M/L attribute. Deliberately invisible: the panel never displays it and no panel action sets it, though a capture line may name it like any other attribute (`pri:H`). Never stripped from tasks that have one.

**Project**:
A task's optional project, possibly dotted into a hierarchy (`home.kitchen`). Read-only in the panel.

**Tag**:
A `+tag` on a task. Captured tasks get the configurable default tags (default: `inbox`) when the line names none itself.

**Annotation**:
A dated note attached to a task. Displayed as a count, never edited.

**Due**:
A task's due date, shown in local calendar days ("today", "tomorrow", "in 3d"). Read-only in the panel.

**Filter**:
A Taskwarrior filter expression typed or picked in the panel narrows which pending tasks are listed.
_Avoid_: Search

**Saved filter**:
A filter expression defined in the plugin's settings, offered as a chip.
_Avoid_: View, preset
