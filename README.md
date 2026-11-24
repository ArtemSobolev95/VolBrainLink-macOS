# VolBrainLink for IsiX and Horos (macOS)

Sends a series from **IsiX DICOM Viewer** or **Horos** to [volBrain](https://volbrain.net) and brings
the PDF report back into the study.

> **Research use only.** volBrain is a free research service whose results are not validated for
> diagnosis. This plugin is not made by or affiliated with the volBrain team.

## Download

Current version: **1.0.0**. Click the package for your viewer:

| Viewer | Download | macOS | Mac |
|---|---|---|---|
| IsiX DICOM Viewer 6.0.3+ (GitHub build) | [**VolBrainLink-IsiX-1.0.0.zip**](https://github.com/ArtemSobolev95/VolBrainLink-macOS/raw/main/downloads/VolBrainLink-IsiX-1.0.0.zip) | 15 or later | Apple silicon and Intel |
| Horos 4.0.1 | [**VolBrainLink-Horos-1.0.0.zip**](https://github.com/ArtemSobolev95/VolBrainLink-macOS/raw/main/downloads/VolBrainLink-Horos-1.0.0.zip) | 11 or later | Apple silicon and Intel |

Each package works on both kinds of Mac. The App Store version of IsiX loads no plugins; use the
[GitHub build of IsiX](https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases).

### Install

1. Quit the viewer.
2. Unzip the package and double-click **Install VolBrainLink.command**.
   If macOS says the developer cannot be verified: System Settings › Privacy & Security ›
   *Open Anyway*, then double-click it again.
3. Open the viewer. *Plugins › Plugins Manager* should list VolBrainLink as loaded.

Menu items: *Plugins › Image Filters › VolBrainLink › volBrain: Send Series* (with a viewer open) and
*Plugins › volBrain Window* (from anywhere). Toolbar buttons: right-click the viewer toolbar ›
*Customize Toolbar…* and drag **volBrain: Window** and **volBrain: Send Series** onto it.
You need your own (free) volBrain account: https://volbrain.net

## How it works

1. **Send Series** (image filters menu or toolbar) converts the series in the viewer to an anonymous
   NIfTI file, `vbl_<random>.nii.gz`. Voxel order and orientation come from the DICOM geometry
   (RAS sform and qform, as dcm2niix writes them); int16 when the values allow, else float32.
2. The **volBrain window** shows the real volbrain.net site. You log in, choose the pipeline, type
   age and sex and submit yourself. When the upload box asks for a file, the plugin offers the
   prepared series instead of a file dialog.
3. While a job is waiting, the plugin loads your **Results** page once every 10 minutes (5–60,
   adjustable) in a hidden web view with the same login. It finds the row with the job's file name.
   When that row has a PDF report link, the plugin downloads the report and shows a notification.
4. **Import Report into Viewer** files the report in the original study as series 9900, one colour
   image (DICOM Secondary Capture, 150 dpi) per page, with the patient and study identifiers of that
   study. Images rather than an Encapsulated PDF, because IsiX inverts the colours of PDF pages in
   Dark Mode. The original PDF stays with the job (Show in Finder).

Only the image volume leaves the Mac. Patient details are kept in
`~/Library/Application Support/VolBrainLink/jobs.plist` to file the report.

## Build

Needs the Xcode command line tools. The plugin SDK headers are in [`third_party/`](third_party).

```sh
./build.sh install                   # IsiX build, installs into IsiX
TARGET=horos ./build.sh install      # Horos build, installs into Horos
TARGET=isix ./package.sh; TARGET=horos ./package.sh   # zips in dist/
```

Or double-click **Build IsiX version.command** / **Build Horos version.command**.

`tests/` has command-line checks of the NIfTI and DICOM writers (plain C, run anywhere):

```sh
cd tests && clang -o tn test_nifti.c ../Sources/VBLNifti.c -lz -lm && ./tn a.nii.gz b.nii.gz && python3 check.py a.nii.gz b.nii.gz
```

## Things to know

- volBrain has no public API. The plugin uses the website as you would; the only automatic part is
  the infrequent Results check and the report download. volBrain may change its pages. If a finished
  job is not recognised, open the report in the volBrain window and click **Import Report into Viewer**.
- The volBrain terms require fully anonymised data, research use, and at most 10 cases a day per user.
  3D head scans contain the face; follow your institution's rules for external research services.
- volBrain deletes uploads and results after 30 days.
