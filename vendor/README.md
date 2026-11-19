# Browser libraries (Word letters, claim PDFs)

Copied without modification from npm (same files as MEG-EAF V2 `vendor/`):

| File | Package | Version | License |
| --- | --- | --- | --- |
| jszip.min.js | jszip | 3.10.2 | MIT / GPLv3; used under MIT |
| docx-preview.min.js | docx-preview | 0.4.1 | Apache-2.0 |
| html2canvas.min.js | html2canvas | 1.4.1 | MIT |
| jspdf.umd.min.js | jspdf | 2.5.1 | MIT |

Loaded only when a Word letter is opened. Word previews run in a sandboxed frame with scripts and network access disabled; no document is sent to a conversion service.

html2canvas and jsPDF (the same versions the MEG-FORMS apps used) are loaded only when a claim's signed PDF is made, on approve / disapprove in the CMS.
