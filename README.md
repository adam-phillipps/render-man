# render-man V-2

pw for remote code repo is `smash`

#####################################################
# Configure for use:
#####################################################
1. Change the directory in render.rb `a_e_dir` to match after effects' working dir
2. Put the backlog sqs address in render
3. finish configuring all the other stuff in `render.rb`
4. determine the `death_ratio` and set it in `worker.rb` constant, defined at the
      top.

#####################################################
# Notes:
#####################################################
1. This repo is part of a pair that works together for the rendering portion
  of the rendering renderness of rendering jobs that is being done.
  The two code bases are:
    1. ruby scripts
      a. `render.rb` configuration
      b. `worker.rb` main file plus logic to run the job
      c. `job.rb` groups most of the s3 and file management together
      d. `spot_maker.rb` is run in a master instance (not here) that spins up
              multiple instances that run off these ruby scripts and AE work.
2. These files work together with the After Effects project (currently located
  on the F: drive).

#####################################################
# TODO:
#####################################################
1. create better bat file
2. refactor for state-machine and client for V-3

#####################################################
# Basic remote repo use for updating and getting the newest code:
#####################################################
******************************************
******************************************
* explanations syntax:
* `$` means at the shell prompt
* `>` at the command line prompt, ruby, irb, debugging, certain git functions
* numbers give you steps
* letters give you different branches in a tree of decisions to make
* `-` notes or things to verify
******************************************
******************************************

UPDATING LOCAL WITH REMOTE MASTER BRANCH
- make sure there's no changes locally, before you try to pull down the newest
1. $ git status
2. if you see files in red
  2a. $ git diff
  2a. see if you can look through the code that it shows you.  lines with `-` prepended to them mean it is removed in your branch and it used to be there in the one you're comparing to.  `+` means the other way around.  Usually removals are in red and additions are in green, to help you see what changes are there.
  2a. if you can see that there wasn't anything really that changed you can do this
    2a-option 1.  this option resets everything and removes the changes for good.
      $ git reset --hard HEAD
  2b. if you see a lot of changes or something that looks like it could have been
    intentional and not for testing, do these steps:
    2b option 1.  this option is easier but the person who made the changes won't
      automatically know where their changes went.
      $ git stash
      $ git status
        - verify you've got no changes to worry about
      $ git reset --hard HEAD
    2b option 2. this option is preferable but harder
      $ git status
        - verify nothing sensative, like files with passwords etc is in the list
        - if there is and you're not comfortable making changes to the code do this:
          - do the steps in 2a and make sure you notify the other people who may
            have made the change
        - else
          open the files, make the necessary changes to revert the changes back
            to the state that the `git status` output told you about.  git status should have showed the way it looked before the change was made.  you just have to make the text in the file look like that text.
3. Do stuff until `git status` says something like "there's nothing to commit"   
4. git pull --rebase
  - hopefully that worked.  if not, try to work through errors.
you're now updated

###############################################
TO CREATE A LOCAL BRANCH TO WORK ON
if you haven't made changes yet but plan on it
  1. Do the steps from UPDATING LOCAL WITH REMOTE MASTER BRANCH
  2. $ git checkout -b <your-branch-name-goes-here>
  go to town.  you're on a new, freshly updated branch and you're ready to make a clean set of changes to push back up to the remote master.

###############################################
TO PUSH CHANGES YOU'VE ALREADY MADE UP TO REMOTE MASTER
if you have made changes and want to push them up
  1. $ git pull
  - that will pull down the remote master code and tell you when it couldn't figure  
    out how to combine your code with it.  It will say "merge conflict" or
    something to that effect.  Open that file and remove the old changes and
    keep your changes and then save the file.  Repeat that for all the files there
    were conflicts in.
  2. $ git commit -m 'add your message here explaining your change to us'
  3. git push
- hopefully all is well