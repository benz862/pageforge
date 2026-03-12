const puppeteer = require('puppeteer');

(async () => {
  const browser = await puppeteer.launch({ headless: "new" });
  const page = await browser.newPage();

  // We load the file directly.
  await page.goto('file:///Volumes/SkillBinder/Page%20Forge/files/pageforge-skillbinder.html');
  
  // Wait for the pdf generation button to be available
  await page.waitForSelector('.btn-generate');
  
  // Inject script to override jsPDF.output so it dumps the metadata back to us, 
  // bypassing the data-uri window open which doesn't work well headless
  await page.evaluate(() => {
    window.originalBuild = window.buildPDF;
    window.buildPDF = async (mode) => {
      try {
        // Redefine jsPDF constructor to intercept output calls
        const OldjsPDF = window.jspdf.jsPDF;
        window.jspdf.jsPDF = class extends OldjsPDF {
           output(type, options) {
              window.capturedPDF = {
                 mode: mode,
                 type: type,
                 options: options,
                 pageCount: this.internal.getNumberOfPages()
              };
              return "";
           }
           save(filename) {
              window.capturedPDF = {
                 mode: mode,
                 filename: filename,
                 pageCount: this.internal.getNumberOfPages()
              };
           }
        };

        await window.originalBuild(mode);
      } catch (err) {
        window.capturedError = err.message;
      }
    };
  });

  // Call it in preview mode
  await page.evaluate(() => window.buildPDF('preview'));
  await page.waitForTimeout(500);

  const previewResult = await page.evaluate(() => window.capturedPDF);
  const previewErr = await page.evaluate(() => window.capturedError);
  
  if (previewErr) {
    console.error("Preview failed:", previewErr);
  } else {
    console.log("Preview executed successfully:", previewResult);
  }

  // Then download mode
  await page.evaluate(() => window.buildPDF('download'));
  await page.waitForTimeout(500);
  
  const dlResult = await page.evaluate(() => window.capturedPDF);
  const dlErr = await page.evaluate(() => window.capturedError);

  if (dlErr) {
    console.error("Download failed:", dlErr);
  } else {
    console.log("Download executed successfully:", dlResult);
  }

  await browser.close();
})();
