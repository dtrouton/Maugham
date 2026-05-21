# History Rewind manual smoke

Run this after `xcodebuild` is green. User executes; report results back.

1. **Setup**
   - Open Maugham. New project → Novel → "Rewind smoke".
   - Type across three paragraphs over ~30 seconds (so the burst fires).
   - ⌘S → label "before-extras" → save.
   - Add two more paragraphs, wait for the burst.
   - In the right pane, ⌘⌥4 to switch to History.

2. **Header Rewind button**
   - Click "Rewind…" in the HistoryPane header.
   - The modal opens. Scrubber shows ticks (typing-burst blue, checkpoint green-tall).
   - Header context line reads "Now — drag the scrubber to revisit a past moment".
   - Doc preview shows current text (with anchor comments stripped).
   - Drag the scrubber to roughly the middle. Preview updates; header line shows the op_id-relative timestamp.
   - Toggle to Diff. Verify red strikethrough on paragraphs that would be removed; green underline on paragraphs that would come back.
   - Footer impact summary line shows "Restoring would undo N words / M paragraphs…".
   - ESC to dismiss. Editor unchanged.

3. **Snapshot here**
   - Reopen Rewind. Scrub to a past op. Click "Snapshot here…".
   - Label "scrubbed-snapshot" → Save.
   - HistoryPane refreshes; new checkpoint row appears at the top of the timeline (latest activity-time).
   - Live editor unchanged.

4. **Restore here**
   - Reopen Rewind. Scrub further back. Click "Restore here…".
   - Confirm sheet shows "Restore [doctitle] to this point?" with the impact summary.
   - Click Restore. Modal closes.
   - Editor reverts; the two extras you typed are gone.
   - In HistoryPane: a new "Rewound" row appears at the top.

5. **Per-row ↺ button**
   - HistoryPane: find a typing_burst row (one of the bursts you made).
   - Click the ↺ button on the right of the row.
   - Modal opens pre-positioned at that op. Preview shows the doc as it was at that point.
   - Click Cancel.

6. **Annotation auto-archive during rewind**
   - Have Claude Desktop running (or skip — use add_note tool manually).
   - Add an annotation on a paragraph. Verify it shows in AnnotationsPane (⌘⌥A).
   - Rewind back to a point before that paragraph existed.
   - In AnnotationsPane: the annotation is gone (or shows in the Resolved filter).
   - In HistoryPane: a "Auto-archived: paragraph removed by rewind" line appears.

7. **Persistence smoke**
   - ⌘Q. Relaunch. Reopen the project from Recents.
   - HistoryPane still shows the Rewound + Snapshot rows. The restored doc text is intact.

If any step fails, report which step + observed behaviour vs. expected.
