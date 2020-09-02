## Creating and Understanding a pScheduler Tool

### 1. Understanding pScheduler tools

Before writing a tool, it's important to understand how tools are used in pScheduler as well as the perfSONAR 
best practices for developers. The wiki (https://github.com/perfsonar/project/wiki) contains help on how to develop for perfSONAR
in general. Examples of tools can be found in the pScheduler source code (anything with tool in the folder name in the 
main directory is a tool). It is also important to look at examples of the two different types of tools: ones that require installing outside tools (such as paris-traceroute) and ones that rely solely on python packages or tools that come with the command line/can be installed with default system command line tools (such as iperf3).

### 2. Running the PDK setup script

Once you understand what you want to accomplish with your tool, you'll want to make sure you have a pScheduler development 
environment set up on your development machine. The instructions for how to do this can be found on the general README page for 
the pScheduler repository. Then, you'll want to run the plugin_dev script as specified in the PDK README. You will need to have the test your tool will be used with already created before you can create your tool. If you are developing your test simultaneously, make sure to create the test with the script first. If you are developing a new tool to be used with a preexisting test, you should just use the name of the preexisting test when running the PDK script. Naming conventions for pScheduler dictate that the name of the tool should exactly match the name of the program being used by the tool. This script will set 
up all of the files you need for your tool and fill in the boilerplate code needed for a basic perfSONAR tool. You
may also want to run the make commands indicated in the PDK README to make sure that everything is ready to go out of the box.

### 3. Developing your tool

After the files are generated, you're ready to begin developing! Below we have a more thorough explanation of all of the files 
and directories generated by the plugin_dev script, which may be helpful to read through before you begin writing code.

### 4. Testing your tool
There are two main ways to test your tool:

1. Testing with scheduled pScheduler tasks or

2. Testing with premade JSON files

It's important to utilize both means of testing in your development workflow. However, for debugging purposes, the second 
testing method is usually more useful in terms of output and is also much faster.

#### Method 1:

-Follow the pScheduler documentation on how to use a tool (https://docs.perfsonar.net/pscheduler_ref_tests_tools.html)

#### Method 2:

_This method is somewhat more involved to set up, but ultimately it will allow you to debug much easier. If you do not run 
your tool in this way, you will **not** be able to see any print statements you generate in your tool code. **This 
includes error messages!** Running your tool in the regular scheduled test format is important to verify that it works 
in that manner because that is how it will be used "in the wild", however, it will "fail silently" when run that way which won't 
help you make progress in developing it._

1. Obtain output JSON

It is really helpful to have your test already developed to a point where it can generate spec json output before you do this step. If it's not ready, you can manually add in all of the options you expect to see in your spec to the example input. 

First, you'll want to run cli-to-spec in your test directory to generate the spec json. However, this alone is not enough to run your test. You'll need to integrate this json with the provided example-json in the tool directory (an outline generated by the PDK). You'll need to insert the spec json you generated with your test into the spec section of the example json file. You can leave the options provided there (they are standard pScheduler options you probably will have included in your test). 

Unless you're testing to ensure that your tool fails with inadequate or incorrect input, make sure you insert all of the options expected by your tool. If you generate your json with cli-to-spec and have missing options that get flagged by your tool, you'll need to reevaluate the link between your test and tool to ensure they're compatible with each other. The spec output from the test is the expected input to the tool.

2. Use the JSON with the run file

You can directly input your json into the tool by using the following command:

```./run < example-test-spec.json```

assuming you used example-test-spec.json as the file for your full spec json input. The run file is where the actual test runs, so directing the spec json directly into this file is sufficient for the vast majority of your tool testing.

3. Get result JSON output

Running run with example spec json shoudl generate result json output. This result json is important for testing your test. It's a good idea to save it into a file, and use that file to test your test. This output result should contain everything you need to get result output from your test. If your test result formatting fails on this output json, you'll want to check that your test is expecting what the tool is providing and that your tool is providing all of the information the test needs to give a full result. 

 ### 5. Debugging your tool
 
 Once your tool is up and running with the directly piped JSON, make sure to test it directly with a pScheduler task. In order to do this, you will need your test to be working as well. First, you'll need to do a ```make cbic``` in both the test and tool directories. You'll need to run a ```make cbic``` in your tool directory any time you make a change to your tool or the change won't be reflected when you run a pScheduler task.

You'll also need to add both the test and the tool to the pScheduler RPM file. This can be found at https://github.com/perfsonar/pscheduler/blob/master/scripts/RPM-BUILD-ORDER.m4 (navigate to directory ```pscheduler/scripts/``` and open ```RPM-BUILD-ORDER.m4```. Any packages (including python packages) or external tools you added to pScheduler to run your test/tool will need to be added to this file in the appropriate section (the section for these is above where you will add your test/tool). Then, you'll need to add the test and tool names in the appropriate sections. Be very careful to spell everything correctly or pScheduler will not recognize your test/tool. This enables pScheduler to make your test and tool during a pScheduler make and adds them to pScheduler. You can then run a make on pScheduler.

## Anatomy of a Tool

### enumerate

Most of this is filled in by the PDK. You'll need to edit the description and make sure the 'tests' field is accurate. That specifies what tests the tool is compatible with. You'll want to be absolutely sure that the test named in there is the test you're co-developing with the tool. If you're adding a tool for a pre-existing test, make sure it's accurate.

### can-run 

You will probably not have to edit this file after PDK generation. This file determines if the tool can be run under the given circumstances. It's important to check that the test name in can-run matches the actual test name. Otherwise, it will refuse to run with the test and give an error message saying it's incompatible.

### duration

This file determines the duration of the specified test. You'll want to designate an appropriate default timeout period for your test here.

### run

This is where the majority of the development for the tool takes place. The code to actually run the tool is written here. Everything that is needed to successfully complete the given test with the given tool needs to be here. You'll be using the input from the test spec to run your tool. Make sure that your tool is expecting the input given by the test spec or else your test and tool won't be compatible with each other. This is the file that will invoke the actual program the tool is written around or be the complete python script to execute the task. Output parsing (turning the results of the command line tool into json results) occurs here as well. This is typically the most consuming part of test/tool development. You'll need to make sure that the result output matches the result input expected by your test.

