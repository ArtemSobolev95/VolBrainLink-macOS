# Changes

## 1.0.0 — first release

- Send Series: 3D series → anonymous vbl_<id>.nii.gz (int16/float32, RAS sform+qform)
- volBrain window: volbrain.net in a web view; the upload box offers the prepared series
- Status checks of the Results page every 5–60 min while a job waits; report download; notifications
- Import Report into Viewer: the report filed in the original study as series 9900, one image per page
  (Secondary Capture: correct colours in Dark Mode, where IsiX inverts PDF pages)
- One Import button: the PDF open in the volBrain window, or the downloaded report of the selected series
- Notifications with a fallback for viewers macOS refuses the current notification API; clicking one opens the job
- Plugins › volBrain Window works without a viewer; toolbar buttons with their own icon
- Log of status checks in ~/Library/Application Support/VolBrainLink/log.txt
