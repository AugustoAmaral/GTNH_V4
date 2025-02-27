const { exec } = require("child_process");
const fs = require("fs");
const util = require("util");
const execPromise = util.promisify(exec);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runCommandWithRetry(command, retries = 250) {
  for (let i = 0; i < retries; i++) {
    try {
      await execPromise(command);
      console.info(
        `Command ${command} executed successfully at attempt number ${i + 1}`
      );
      return;
    } catch (error) {
      console.info(`Attempt ${i + 1}: Failed to execute command`, error);
      console.info("Retrying in a second...");
      await sleep(1000);
      if (i === retries - 1)
        throw new Error(`Failed after ${retries} attempts`);
    }
  }
}

async function runBackup() {
  const now = new Date();
  const formattedDate = now.toISOString().slice(0, 16).replace("T", "T");
  console.info(`Actual datetime is ${formattedDate}`);

  try {
    fs.appendFileSync("lastUpdate.txt", `Last update ${formattedDate}\n`);
    await runCommandWithRetry("git add .");
    await sleep(2 * 60 * 1000);
    await runCommandWithRetry(`git commit -m 'Auto backup - ${formattedDate}'`);
    await sleep(60 * 1000);
    await runCommandWithRetry("git push");
  } catch (error) {
    console.info("Error during backup:", error);
  }
}

async function main() {
  // Run backup once before setting the interval
  await runBackup();

  // Set interval to run backup every hour
  setInterval(async () => {
    await runBackup();
  }, 3600 * 1000);
}

main();
