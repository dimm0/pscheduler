## Creating and Understanding a pScheduler Archiver

### 1. Understanding pScheduler Archivers
Before writing an archiver, it's important to understand how archivers are used in pScheduler as well as the perfSONAR 
best practices for developers. The wiki (https://github.com/perfsonar/project/wiki) contains help on how to develop for perfSONAR
in general. Examples of archivers can be found in the pScheduler source code (anything with archiver in the folder name in the 
main directory is an archiver).

### 2. Running the PDK setup script
Once you understand what you want to accomplish with your archiver, you'll want to make sure you have a pScheduler development 
environment set up on your development machine. The instructions for how to do this can be found on the general README page for 
the pScheduler repository. Then, you'll want to run the plugin_dev script as specified in the PDK README. This script will set 
up all of the files you need for your archiver and fill in the boilerplate code needed for a basic perfSONAR archiver. You
may also want to run the make commands indicated in the PDK README to make sure that everything is ready to go out of the box.

### 3. Developing your archiver
After the files are generated, you're ready to begin developing! Below we have a more thorough explanation of all of the files 
and directories generated by the plugin_dev script, which may be helpful to read through before you begin writing code.

### 4. Testing your archiver
There are two main ways to test your archiver:

1. Testing with scheduled pScheduler tasks or

2. Testing with premade JSON files

It's important to utilize both means of testing in your development workflow. However, for debugging purposes, the second 
testing method is usually more useful in terms of output and is also much faster.

#### Method 1:

-Follow the pScheduler documentation on how to use an archiver (http://docs.perfsonar.net/release_candidates/4.1b1/pscheduler_ref_archivers.html)

#### Method 2:

_This method is somewhat more involved to set up, but ultimately it will allow you to debug much easier. If you do not run 
your archiver in this way, you will **not** be able to see any print statements you generate in your archiver code. **This 
includes error messages!** Running your archiver in the regular scheduled test format is important to verify that it works 
in that manner because that is how it will be used "in the wild", however, it will "fail silently" when run that way which won't 
help you make progress in developing it._

1. Obtain output JSON

-The easiest way to do this is to use the syslog archiver provided by pScheduler
Run a pScheduler task of your choice (a good default choice is idle) and output to the syslog archiver. The syslog archiver 
will generate a JSON blob of output that you can then use with your archiver. To access the output from the syslog archiver 
type in 
```sudo less /var/log/messages``` and use ```<``` to go to the end of the file (where your output should be if you just ran
 the task). Then just go ahead and copy that JSON blob at the end and save it somewhere useful.
 
 2. Create basic JSON for your archiver
 
 -The JSON piped directly into the archiver has two main parts: the archiver input that is fed to every archiver and the output from the task. To create a JSON file with all the data your archiver needs, simply follow this template used by 
 pScheduler when it generates the JSON that is actually used by an archiver when used normally: https://github.com/perfsonar/pscheduler/blob/b1e76b88c0ec712b43b01bb51e47575f40e0d49c/pscheduler-server/pscheduler-server/daemons/archiver.raw#L588
 
 -Only insert the fields you actually need. ```archiver-data``` will be replaced with a JSON blob that contains the actual data fields your archiver is expecting to see as input. Everything else can be filled in from the output JSON blob generated 
 by the syslog archiver. Delete any fields that are unnecessary based on the task you ran.
 
 -Once you generate this JSON, I recommend using jq on the file to make sure it's a valid JSON file. pScheduler will generate it's own specific error messages if the JSON is formatted in ways that it cannot accept. It's much easier to debug if you can deduce that errors you are getting are pScheduler specific and not just because your JSON is formatted incorrectly. If you have never used jq, you can find more documentation on how to use it here: https://stedolan.github.io/jq/ (You should not 
 need to install anything, your pScheduler development environment should come with jq already ready to use).
 
 3. Formatting the JSON for use with pScheduler
 
 -pScheduler JSON has some unique quirks specific to how it is parsed. In order to have your archiver successfully parse and use your JSON blob, you'll need to format it as follows.
 
 -Due to the way the JSON is parsed, our JSON needs to be in "ugly" format. When you're writing your JSON, use ```jq . filename``` to see the beautified JSON and you can also pipe it into a file to work with. When you're done creating the JSON, 
 you'll need to uglify it (minify it) so that it will be accepted by your archiver. Doing this with jq is easy, just use ```jq -c . < filename``` to minify your file. 
 
 -JSON for pScheduler is designed to be compatible with a JSON streaming standard. For the purposes of testing with a single JSON blob, we don't need to actually stream data, but we do need to make our single JSON blob compliant with the streaming standards. In order to do so, we need to put an RS character at the beginning of our file that denotes the start of a file. Unfortunately, this character is unprintable so we can't just copy and paste it, we need to generate a new JSON file that contains the character and the contents of our JSON file. Use this command to add that character to the front of your JSON file: ```sudo sh -c '(printf "\x1e" && cat input_file) > output_file'```.
 
 -As an aside, you won't see any indication of this character if you ```cat``` out the JSON file. If you want to verify that the character is in fact there, you'll want to use vim or another text editor (in vim, the character will look like this ```^^```). 
 
 4. Feeding the JSON to your archiver
 
 -Now that your JSON is correctly formatted, you can go ahead and feed it directly into your archiver. To do so, go to the directory where your archive file is and use the command ```./archive < my_json_file```. This will run your archiver and it will take your JSON file and treat it as though it is the JSON output it would get from pScheduler. If you have any print statements inside your archive file for debugging purposes, you will see this printed to the command line.

## Anatomy of an Archiver

When you generate a pScheduler archiver using the plugin_dev template, all of the essential files will be created for you along with the basic code required for every archiver. Provided here is a basic guide on the purpose of all those files and what you, as the developer, are expected to do with them in the process of creating your archiver.

### archive
This file handles the actual archiving process. The input to this file consists of a JSON blob containing information about the test that was run as well as any configuration details provided by the user running the archiver (for more detail on the contents of that JSON blob, see the section above regarding testing an archiver). In this file, you need to define the archive method itself and describe how the data should be archived.

### data-is-valid
This file verifies that the data provided by the user when they call the archiver (the JSON blob used to specify archiver configuration) is valid and has the data needed for the archiver to run. This is also where you will define the schema of your input data. The schema simply describes the format of the data that is expected by a certain version of your archiver. The best practice is to always define the schema, even if you only have one version of your archiver. However, the scheme becomes absolutely required once your archiver exists in multiple versions which may expect different inputs. Omitting it can cause your archiver to fail.

### enumerate
This file describes the archiver in a JSON format. As a developer, there is very little you need to edit here after the file has been generated. You should check the contents to make sure they are thorough and accurate before you release your archiver.

### name.txt
"name" will be replaced by the name of your archiver. This file serves as the documentation for your archiver. While this file will be autogenerated for you, it will not contain any helpful documentation until you add it. This is a space for all documentation that is specific to your archiver, not documentation about how to use archivers and/or pScheduler in general. This is a good place to describe the data schema used by your archiver, what your archiver does, and anything else someone might need to know to get it working successfully. 

### Makefiles
An autogenerated archiver template will have two Makefiles. Typically, there should be no need to edit them after generation.

### spec
This file is a spec for the RPM build of pScheduler, describing your archiver. Typically, there will be no need to edit this file.
