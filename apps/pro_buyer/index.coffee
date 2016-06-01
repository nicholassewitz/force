express = require 'express'
adminOnly = require '../../lib/middleware/admin_only'
JSONPage = require '../../components/json_page'

app = module.exports = express()
app.set 'views', __dirname
app.set 'view engine', 'jade'

page = new JSONPage
  name: 'professional-buyer',
  paths:
    show: '/professional-buyer'
    edit: '/professional-buyer/edit'

{ data, edit, upload } = require('../../components/json_page/routes')(page)
{ get, middleware } = require('./routes')(page)

app.get page.paths.show, adminOnly, get.index
app.get page.paths.show + '/data', adminOnly, data
app.get page.paths.edit, adminOnly, edit
app.post page.paths.edit, adminOnly, upload
app.get page.paths.show + '/complete', adminOnly, middleware, get.complete