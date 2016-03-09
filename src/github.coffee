# Description:
#  List and schedule reminders about open pull requests on github
#
# Dependencies:
#  - coffeescript
#  - cron
#  - octokat
#  - moment
#  - underscore
#
# Configuration:
#   HUBOT_GITHUB_TOKEN - Github Application Token
#   HUBOT_GITHUB_ORG - Github Organization Name (the one in the url)
#   HUBOT_GITHUB_REPOS_MAP (format: "{\"web\":\"frontend\",\"android\":\"android\",\"ios\":\"ios\",\"platform\":\"web\"}"
#
# Commands:
#   hubot github iam <username> - Let hubot know what your github username is
#   hubot github users - List the github users hubot knows about
#   hubot github open [for <user>] - Shows a list of open pull requests for the repo of this room [optionally for a specific user]
#   hubot github notification hh:mm - I'll remind about open pull requests in this room at hh:mm every weekday.
#   hubot github list notifications - See all pull request notifications for this room.
#   hubot github notifications in every room - Be nosey and see when other rooms have their notifications set
#   hubot github delete hh:mm notification - If you have a notification at hh:mm, I'll delete it.
#   hubot github delete all notifications - Deletes all notifications for this room.
#
# Author:
#   ndaversa

unless (github_url = process.env.HUBOT_GITHUB_URL)?
  github_url = "https://github.com"
token = process.env.HUBOT_GITHUB_TOKEN
githubOrg = process.env.HUBOT_GITHUB_ORG
repos = process.env.HUBOT_GITHUB_REPOS_MAP
debug = process.env.HUBOT_GITHUB_DEBUG
slacktoken = process.env.SLACK_API_TOKEN

_ = require 'underscore'
moment = require 'moment'
cronJob = require("cron").CronJob
Octokat = require('octokat')
Promise = require 'bluebird'
SlackAPI = require 'slack-node'
AsciiTable = require 'ascii-table'
rootURL = github_url + "/api/v3"
octo = new Octokat({
  token: token
  rootURL: rootURL
})

slack = new SlackAPI(slacktoken)

module.exports = (robot) ->

  getGithubUsers = ->
    robot.brain.get('github-users') or []

  saveGithubUsers = (users) ->
    robot.brain.set 'github-users', users

  getNotifications = ->
    robot.brain.get('github-notifications') or []

  saveNotifications = (notifications) ->
    robot.brain.set 'github-notifications', notifications

  lookupUserWithGithub = (github) ->
    users = getGithubUsers()
    result = (user for user in users when user.github is github.login) if github
    if result?.length is 1
      return "<@#{result[0].id}>"
    else if github
      return github.login
    else
      return "Unassigned"

  notificationShouldFire = (notification) ->
    now = new Date
    currentHours = now.getHours()
    currentMinutes = now.getMinutes()
    notificationHours = notification.time.split(':')[0]
    notificationMinutes = notification.time.split(':')[1]
    try
      notificationHours = parseInt notificationHours, 10
      notificationMinutes = parseInt notificationMinutes, 10
    catch _error
      return false
    if notificationHours is currentHours and notificationMinutes is currentMinutes
      return true
    return false

  getNotificationsForRoom = (room) ->
    _.where getNotifications(), room: room

  checkNotifications = ->
    notifications = getNotifications()
    _.chain(notifications).filter(notificationShouldFire).pluck('room').each doNotification

  doNotification = (room) ->
    listOpenPullRequestsForRoom room

  findRoom = (msg) ->
    room = msg.envelope.room
    if _.isUndefined(room)
      room = msg.envelope.user.reply_to
    room

  saveNotification = (room, time) ->
    notifications = getNotifications()
    newNotification =
      time: time
      room: room
    notifications.push newNotification
    saveNotifications notifications

  clearAllNotificationsForRoom = (room) ->
    notifications = getNotifications()
    notificationsToKeep = _.reject(notifications, room: room)
    saveNotifications notificationsToKeep
    notifications.length - (notificationsToKeep.length)

  clearSpecificNotificationForRoom = (room, time) ->
    notifications = getNotifications()
    notificationsToKeep = _.reject notifications,
      room: room
      time: time
    saveNotifications notificationsToKeep
    notifications.length - (notificationsToKeep.length)

  listOpenPullRequestsForRoom = (room, user) ->
    repojson = JSON.parse repos
    repoarr = repojson[room]

    if not repoarr
      robot.messageRoom room, "There is no github repository associated with this room (#{room}). Contact your friendly <@#{robot.name}> administrator for assistance"
      return

    message = ""
    msg = {
      text: "Pull requests"
      user:
        name: robot.name
      done: false
      room: "##{room}"
    }
    attachments = new Array()
    commenters = { }
    commentme = new Array()

    promout = Promise.all repoarr.map (repoinst) ->
        repo = octo.repos(githubOrg, repoinst)
        repo.pulls.fetch(state: "open").then (prs) ->
          return Promise.all prs.map (pr) ->
              if not user? or pr.assignee?.login.toLowerCase() is user.toLowerCase()
                  return repo.pulls(pr.number).fetch()
              return
        .then ( prs ) ->
            return Promise.all prs.map (pr) ->
                totcomments = pr.comments + pr.reviewComments
                attach =
                  fallback: "##{pr.number} - #{pr.title}"
                  color: "#{if pr.mergeable then "good" else "danger"}"
                  title: "[#{pr.head.repo.name}] - ##{pr.number} - #{pr.title}"
                  title_link: pr.htmlUrl
                  text: "#{totcomments} comments"
                #  fields: attfields
                attachments.push attach
                return repo.pulls(pr.number).comments.fetch()
        .then (comments) ->
            return Promise.all comments.map (commentset) ->
                commentcount = 0
                if (commentset[0]?.htmlUrl?)
                  prurl = commentset[0].htmlUrl

                  for comment in commentset
                    email = comment.user.login
                    if (commenters[email]?)
                      commenters[email] += 1
                    else
                      commenters[email] = 1
                    commentcount += 1

                prurl = commentset[0]?.pullRequestUrl
                if prurl?
                  prnum = prurl.substring(prurl.lastIndexOf("/") + 1)
                  return repo.pulls(prnum).fetch()
                else
                  return
        .then (prs) ->
            return Promise.all prs.map (pr) ->
              if pr?.reviewCommentsUrl?
                return octo.fromUrl(pr.reviewCommentsUrl).fetch()
              else
                return
        .then (reviewcoms) ->
            return Promise.all reviewcoms.map (reviewcom) ->
              commentcount = 0
              if (reviewcom?)
                for comment in reviewcom
                  email = comment.user.login
                  if (commenters[email]?)
                    commenters[email] += 1
                  else
                    commenters[email] = 1
                  commentcount += 1

    promout.then ( dataprom ) ->
        leaders = new AsciiTable 'PR Comment Leaderboard'
        leaders.setHeading('User', 'Comments')

        robot.logger.info Object.keys(commenters)

        for key in Object.keys(commenters)
          leaders.addRow key, commenters[key]

        robot.logger.info leaders.toString()

        leaders.sortColumn 1, (a,b) ->
          return b - a

        robot.logger.info leaders.toString()

        if attachments.length is 0
          message = "No matching pull requests found"
          robot.messageRoom room, message
        else
          message = "Open Skylight Pull Requests"
          #robot.logger.info attachments
          robot.messageRoom room, message
          robot.emit 'slack.attachment',
            message: msg
            content: attachments

          #robot.logger.info attachments
          robot.messageRoom room, "```" + leaders.toString() + "```"
          # robot.emit 'slack.attachment',
          #   message: leaders.toString()
          #   content: leaders.toString()

    # promout.then (prs) ->
    #     return Promise.all prs.map (pr) ->
    #       return octo.fromUrl(pr.commentsUrl).fetch()
    # .then ( comments ) ->
    #   return Promise.all comments.map (commentset) ->
    #     for comment in commentset
    #       email = comment.user.login.replace("-",".").concat("@apx-labs.com")
    #       if (commenters[email]?)
    #         commenters[email] += 1
    #       else
    #         commenters[email] = 1
    #       commentcount += 1
    #     robot.logger.info commenters
    #     commentme.push "test"
    #
    #     robot.logger.info commentcount
    #     robot.logger.info "com: #{commentme}"
    #     robot.logger.info "#{attachments}"
    #     # for email, count in commenters
    #     #   users = robot.brain.data.users
    #     #   robot.logger.info email
    #     #   for k,user of users
    #     #     slackuser = user['slack']
    #     #     for k, profile of slackuser when k is 'profile'
    #     #       robot.logger.info "#{profile.email} is my email"
    #
    #     # attach =
    #     #   fallback: "##{pr.number} - #{pr.title}"
    #     #   color: "#{if pr.mergeable then "good" else "danger"}"
    #     #   title: "[#{pr.head.repo.name}] - ##{pr.number} - #{pr.title}"
    #     #   title_link: pr.htmlUrl
    #     #   text: "#{commentcount} comments"
    #     # #  fields: attfields
        # attachments.push attach



  robot.respond /(?:github|gh|git) delete all notifications/i, (msg) ->
    notificationsCleared = clearAllNotificationsForRoom(findRoom(msg))
    msg.send """
      Deleted #{notificationsCleared} notification#{if notificationsCleared is 1 then "" else "s"}.
      No more notifications for you.
    """

  robot.respond /(?:github|gh|git) delete ([0-5]?[0-9]:[0-5]?[0-9]) notification/i, (msg) ->
    [__, time] = msg.match
    notificationsCleared = clearSpecificNotificationForRoom(findRoom(msg), time)
    if notificationsCleared is 0
      msg.send "Nice try. You don't even have a notification at #{time}"
    else
      msg.send "Deleted your #{time} notification"

  robot.respond /(?:github|gh|git) notification ((?:[01]?[0-9]|2[0-4]):[0-5]?[0-9])$/i, (msg) ->
    [__, time] = msg.match
    room = findRoom(msg)
    saveNotification room, time
    msg.send "Ok, from now on I'll remind this room about open pull requests every weekday at #{time}"

  robot.respond /(?:github|gh|git) list notifications$/i, (msg) ->
    notifications = getNotificationsForRoom(findRoom(msg))
    if notifications.length is 0
      msg.send "Well this is awkward. You haven't got any github notifications set :-/"
    else
      msg.send "You have pull request notifcations at the following times: #{_.map(notifications, (notification) -> notification.time)}"

  robot.respond /(?:github|gh|git) notifications in every room/i, (msg) ->
    notifications = getNotifications()
    if notifications.length is 0
      msg.send "No, because there aren't any."
    else
      msg.send """
        Here's the notifications for every room: #{_.map(notifications, (notification) -> "\nRoom: #{notification.room}, Time: #{notification.time}")}
      """

   robot.respond /(?:github|gh|git) iam (?:@?)(.*)$/, (msg) ->
     [__, githubUsername] = msg.match
     users = getGithubUsers()
     user = (users.filter (user) -> user.id is msg.message.user.id)[0]

     if not user
       user =
         id: msg.message.user.id
         github: githubUsername
       users.push user
     else
       user.id = msg.message.user.id
       user.github = githubUsername

     saveGithubUsers users
     msg.reply "Thanks, I'll remember that <@#{user.id}> is `#{user.github}` on github"

   robot.respond /(?:github|gh|git) (?:list|show|users)(?:\s+users)?$/, (msg) ->
     users = getGithubUsers()
     message = ""
     for user in users
       message += "\n<@#{user.id}> is `#{user.github}` on github"

     if message.length is 0
       message = "I don't have any github users yet"

     msg.reply message

  robot.respond /(github|gh|git) help/i, (msg) ->
    msg.send """
      I can remind you about open pull requests for the repo that belongs to this channel
      Use me to create a notification, and then I'll post in this room every weekday at the time you specify. Here's how:

      #{robot.name} github iam <username> - Let hubot know what your github username is
      #{robot.name} github users - List the github users hubot knows about
      #{robot.name} github open [for <user>] - Shows a list of open pull requests for the repo of this room [optionally for a specific user]
      #{robot.name} github notification hh:mm - I'll remind about open pull requests in this room at hh:mm every weekday.
      #{robot.name} github list notifications - See all pull request notifications for this room.
      #{robot.name} github notifications in every room - Be nosey and see when other rooms have their notifications set
      #{robot.name} github delete hh:mm notification - If you have a notification at hh:mm, I'll delete it.
      #{robot.name} github delete all notifications - Deletes all notifications for this room.
    """

  robot.respond /(?:github|gh|git) (?:prs|open)(?:\s+(?:for|by)\s+(?:@?)(.*))?/i, (msg) ->
    [__, who] = msg.match

    if who is 'me'
      who = msg.message.user?.name?.toLowerCase()

    if who?
      who = robot.brain.userForName who
      githubUser = (getGithubUsers().filter (user) -> user.id is who.id)[0]?.github

      if not githubUser
        msg.reply """
          I don't know <@#{who.id}>'s github username
          Please have <@#{who.id}> tell me by saying `#{robot.name} github iam <username>`
        """
        return

    listOpenPullRequestsForRoom msg.message.room, githubUser

  robot.brain.once 'loaded', ->
    # Run a cron job that runs every minute, Monday-Friday
    new cronJob('0 * * * * 1-5', checkNotifications, null, true)
