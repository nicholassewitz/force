_ = require 'underscore'
Q = require 'bluebird-q'
sd = require('sharify').data
Article = require '../../models/article'
Articles = require '../../collections/articles'
Section = require '../../models/section'
Sections = require '../../collections/sections'
embedVideo = require 'embed-video'
request = require 'superagent'
{ crop } = require '../../components/resizer'
{ POST_TO_ARTICLE_SLUGS, MAILCHIMP_KEY, SAILTHRU_KEY, SAILTHRU_SECRET, GALLERY_INSIGHTS_SECTION_ID, PARSELY_KEY, PARSELY_SECRET } = require '../../config'
sailthru = require('sailthru-client').createSailthruClient(SAILTHRU_KEY,SAILTHRU_SECRET)
{ stringifyJSONForWeb } = require '../../components/util/json.coffee'

@articles = (req, res, next) ->
  Q.allSettled([
    (sections = new Sections).fetch(data: featured: true)
    (articles = new Articles).fetch(
      data:
        published: true
        limit: 50
        sort: '-published_at'
        featured: true
    )
    if res.locals.sd.CURRENT_USER?.email?
      subscribedToEditorial res.locals.sd.CURRENT_USER.email, (err, subscribed) ->
        res.locals.sd.SUBSCRIBED_TO_EDITORIAL = subscribed
  ]).catch(next).then =>
    res.locals.sd.ARTICLES = articles.toJSON()
    res.locals.sd.ARTICLES_COUNT = articles.count
    section = sections.running()?[0]
    res.render 'articles', section: section, articles: articles, crop: crop

@article = (req, res, next) ->
  new Article(id: req.params.slug).fetchWithRelated
    accessToken: req.user?.get('accessToken')
    error: res.backboneError
    success: (data) ->
      if req.params.slug isnt data.article.get('slug')
        return res.redirect "/article/#{data.article.get 'slug'}"
      res.locals.sd.SLIDESHOW_ARTWORKS = data.slideshowArtworks?.toJSON()
      res.locals.sd.ARTICLE = data.article.toJSON()
      res.locals.sd.FOOTER_ARTICLES = data.footerArticles.toJSON()
      res.locals.sd.RELATED_ARTICLES = data.relatedArticles?.toJSON()
      res.locals.sd.SUPER_SUB_ARTICLE_IDS = data.superSubArticleIds
      res.locals.sd.SCROLL_ARTICLE = getArticleScrollType(data)
      res.locals.jsonLD = stringifyJSONForWeb(data.article.toJSONLD())

      user = res.locals.sd.CURRENT_USER
      setupEmailSubscriptions user, data.article, (results) ->
        res.locals.sd.MAILCHIMP_SUBSCRIBED = results.mailchimp
        res.locals.sd.SUBSCRIBED_TO_EDITORIAL = results.editorial

        topParselyArticles data.article, (parselyArticles) ->
          res.locals.sd.PARSELY_ARTICLES = parselyArticles
          res.render 'article', _.extend data, embedVideo: embedVideo
      return

setupEmailSubscriptions = (user, article, cb) ->
  return cb({ mailchimp: false, editorial: false }) unless user?.email
  if _.contains article.get('section_ids'), sd.GALLERY_INSIGHTS_SECTION_ID
    subscribedToGI user.email, (isSubscribed) ->
      cb { mailchimp: isSubscribed, editorial: false }
  else if article.get('author_id') is sd.ARTSY_EDITORIAL_ID
    subscribedToEditorial user.email, (err, isSubscribed) ->
      cb { editorial: isSubscribed, mailchimp: false }
  else
    cb { mailchimp: false, editorial: false }

getArticleScrollType = (data) ->
  # Only Artsy Editorial and non super/subsuper articles can have an infinite scroll
  if data.relatedArticles?.length or data.article.get('author_id') isnt sd.ARTSY_EDITORIAL_ID
    'static'
  else
    'infinite'

@redirectPost = (req, res, next) ->
  res.redirect 301, req.url.replace 'post', 'article'

@redirectArticle = (req, res, next) ->
  res.redirect 301, req.url.replace 'article', 'articles'

@redirectMagazine = (req, res, next) ->
  res.redirect 301, req.url.replace 'magazine', 'articles'

@section = (req, res, next) ->
  new Section(id: req.params.slug).fetch
    error: -> next()
    success: (section) ->
      return next() unless req.params.slug is section.get('slug')
      new Articles().fetch
        data:
          published: true
          limit: 100
          sort: '-published_at'
          section_id: section.get('id')
        error: res.backboneError
        success: (articles) ->
          res.locals.sd.ARTICLES = articles.toJSON()
          res.locals.sd.ARTICLES_COUNT = articles.count
          res.locals.sd.SECTION = section.toJSON()
          if res.locals.sd.CURRENT_USER?.email? and res.locals.sd.SECTION.id is GALLERY_INSIGHTS_SECTION_ID
            email = res.locals.sd.CURRENT_USER?.email
            subscribedToGI email, (cb) ->
              res.locals.sd.MAILCHIMP_SUBSCRIBED = cb
              res.render 'section', section: section, articles: articles
          else
            res.locals.sd.MAILCHIMP_SUBSCRIBED = false
            res.render 'section', section: section, articles: articles

@form = (req, res, next) ->
  request.post('https://us1.api.mailchimp.com/2.0/lists/subscribe')
    .send(
      apikey: MAILCHIMP_KEY
      id: sd.GALLERY_INSIGHTS_LIST
      email: email: req.body.email
      send_welcome: true
      merge_vars:
        MMERGE1: req.body.fname
        MMERGE2: req.body.lname
        MMERGE3: 'Opt-in (artsy.net)'
      double_optin: false
      send_welcome: true
    ).end (err, response) ->
      if (response.ok)
        res.send req.body
      else
        res.send(response.status, response.body.error)

subscribedToGI = (email, cb) ->
  request.get('https://us1.api.mailchimp.com/2.0/lists/member-info')
    .query
      apikey: MAILCHIMP_KEY
      id: sd.GALLERY_INSIGHTS_LIST
      "emails[0][email]": email
    .timeout 3000
    .end (err, response) ->
      cb response.body.success_count is 1

subscribedToEditorial = (email, cb) ->
  sailthru.apiGet 'user', { id: email }, (err, response) ->
    return cb err, false if err
    cb null, response.vars?.receive_editorial_email

@editorialForm = (req, res, next) ->
  sailthru.apiPost 'user',
    id: req.body.email
    lists:
      "#{sd.SAILTHRU_MASTER_LIST}": 1
    name: req.body.name
    vars:
      source: 'editorial'
      receive_editorial_email: true
      email_frequency: 'daily'
  , (err, response) ->
    if response.ok
      res.send req.body
    else
      res.status(500).send(response.errormsg)

topParselyArticles = (article, cb) ->
  return cb [] unless article.hasTopStories()
  request
    .get('https://api.parsely.com/v2/analytics/posts')
    .query
      apikey: PARSELY_KEY
      secret: PARSELY_SECRET
      limit: 10
      days: 7
      sort: '_hits'
    .end (err, response) ->
      return cb [] if err
      posts = _.where response.body.data, section: 'Editorial'
      return cb posts
