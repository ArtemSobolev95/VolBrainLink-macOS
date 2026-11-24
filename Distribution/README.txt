VolBrainLink @VERSION@ — send a series from IsiX or Horos to volBrain and get the PDF report back
==================================================================================================

Research use only. volBrain (volbrain.net) is a free research service; its results are not validated
for diagnosis. This plugin is not made by or affiliated with the volBrain team.

INSTALL
  Quit the viewer, double-click "Install VolBrainLink.command", open the viewer.
  If macOS says the developer cannot be verified: System Settings > Privacy & Security > Open Anyway.

USE
  1. Open the 3D series in a viewer (a whole-brain 3D T1 with ~1 mm voxels for most pipelines;
     also FLAIR for lesionBrain / DeepLesionBrain, T2 for pBrain or HIPS).
  2. Image filters menu > "volBrain: Send Series". The series becomes an anonymous file
     vbl_<random>.nii.gz and the volBrain window opens. For two-input pipelines, send both series.
  3. Log in on the volBrain page (first time only; the login is remembered).
  4. Choose the pipeline. Type the age and sex shown under the page into the volBrain form if you
     want normative ranges. Click the upload box: the plugin offers the prepared file. Click
     "Upload This File", then submit on volBrain as usual.
  5. Click RESULTS on the volBrain site once. The plugin remembers that page for its status checks.
  6. While a job is waiting, the plugin looks at the Results page every 10 minutes (5-60, your
     choice). When the report is ready you get a notification. Open "volBrain: Window" and click
     "Import Report into Viewer": the report becomes series 9900 in the original study,
     one image per page.

  If a finished job is not recognised (volBrain may change its pages), open the PDF report on the
  Results page inside the volBrain window and click "Import Report into Viewer".

WHAT IS SENT
  Only the image volume, as NIfTI, named vbl_<random>.nii.gz. The NIfTI header has no text fields
  filled. Patient name, ID and dates stay on this Mac (~/Library/Application Support/VolBrainLink),
  where they are used only to file the report in the right study. volBrain's terms require fully
  anonymised data: faces can be reconstructed from 3D head scans, so follow your institution's
  rules on sending patient images to an external research service.
  volBrain accepts 10 cases per user per day.
