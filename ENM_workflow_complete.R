##########  SPECIES DISTRIBUTION MODELING
### load packages
library(raster)
library(rgdal)
library(dismo)
library(ENMeval)
library(megaSDM)
library(SDMtune)
library(ecospat)
library(MASS)
library(dplyr)
library(ggplot2)
library(extrafont)
library(rasterVis)

########################################################################################################################################
####  import .grd layers
env <- raster::stack(list.files(path = 'layers/grd', pattern = '.grd$', full.names = T))
plot(env[[1]])
names(env)

####  load occs ::: full dataset
occs <- read.csv('occs/chosenicus_occ_full.csv') %>% select(1,2,3)
colnames(occs) = c('species', 'long', 'lat')
head(occs)

## thin occs data
occs <- SDMtune::thinData(coords = occs, env = env, x = 'long', y = 'lat')
write.csv(occs, 'occs/chosenicus_occ_full_1km_thinned.csv')
head(occs)

## generate calibration area ::: use megaSDM package
occlist <- list.files(path = 'buffers/buff_occ', pattern = '.csv', full.names = T)

BackgroundBuffers(occlist = occlist, envdata = env, output = 'buffers', 
                  buff_distance = 0.45)

buff <- readOGR('buffers/chosenicus_occ_full_1km_thinned.shp')

## crop layers to calibration area
env_calib <- raster::mask(env, buff)
plot(env_calib[[1]])

#### target group background sampling
# create bias layer
# load thinned target group bg clipped to the calibration area
targ <- read.csv('targ_bg2/targ/targ_bg_thinned_calib.csv') %>% select(3,4)
head(targ)

plot(env[[1]], col = 'grey', legend = F)  ## un-clipped raster for reference
plot(buff, border = 'blue', lwd = 3, add = T)  ## plot buffer over the full raster
points(targ)  ## plot target group points

targ.ras <- rasterize(targ, env_calib, 1)
plot(targ.ras)

targ.pres <- which(values(targ.ras) == 1)
targ.pres.locs <- coordinates(targ.ras)[targ.pres, ]

targ.dens <- MASS::kde2d(targ.pres.locs[,1], targ.pres.locs[,2], 
                         n = c(nrow(targ.ras), ncol(targ.ras)),
                         lims = c(extent(env_calib)[1], extent(env_calib)[2], 
                                  extent(env_calib)[3], extent(env_calib)[4]))

targ.dens.ras <- raster(targ.dens, env_calib)
targ.dens.ras2 <- resample(targ.dens.ras, env_calib)
bias.layer <- raster::mask(targ.dens.ras2, buff)
crs(bias.layer) = crs(env_calib)
plot(bias.layer)

## export bias layer ::: grd & bil
writeRaster(bias.layer, 'targ_bg2/targ/bias.file/bias_layer.grd', overwrite = T)  # grd
writeRaster(bias.layer, 'targ_bg2/targ/bias.file/bias_layer.bil', overwrite = T)  # bil

writeLines(showWKT(crs(bias.layer, asText=T)), extension('targ_bg2/targ/bias.file/bias_layer.grd', 'prj'))
writeLines(showWKT(crs(bias.layer, asText=T)), extension('targ_bg2/targ/bias.file/bias_layer.bil', 'prj'))


## sample target group bg points
length(which(!is.na(values(subset(env_calib, 1)))))

targ.bg <- xyFromCell(bias.layer, 
                      sample(which(!is.na(values(subset(env_calib, 1)))), 10000,
                                         prob = values(bias.layer)[!is.na(values(subset(env_calib, 1)))])) %>% as.data.frame()

colnames(targ.bg) = colnames(occs[, c(2,3)])
head(targ.bg)

write.csv(targ.bg, 'targ_bg2/targ/bias.file/targ_bg_calib.csv')

plot(env[[1]], col = 'grey', legend = F)  ## un-clipped raster for reference
plot(buff, border = 'blue', lwd = 3, add = T)  ## plot buffer over the full raster
points(targ.bg)  ## plot target group bg points


#########################################################################################################################################
######## select environmental variables
## data-driven approach using SDMtune
cor.bg <- prepareSWD(species = 'bgs', a = targ.bg, env = env_calib, categorical = NULL)
plotCor(cor.bg, method = 'spearman', cor_th = 0.7)
corVar(cor.bg, method = 'spearman', cor_th = 0.7)

## STEP 1 ::: remove variables with low importance
## first generate a default MaxEnt model
data_def <- prepareSWD(species = 'pcho', p = occs[, c(2,3)], 
                       a = targ.bg, env = env_calib, categorical = NULL)

c(train, test) %<-% trainValTest(data_def, test = 0.2)
(default_model <- train(method = 'Maxent', data = train))

varImp(default_model, permut = 10)

cat('Testing TSS before', tss(default_model, test = test))

reduced_var_mod <- reduceVar(default_model, th = 1, metric = 'tss', 
                             test = test, permut = 10, use_jk = T, use_pc = T)

cat('Testing TSS after', tss(reduced_var_mod, test = test))

## STEP 2 ::: remove highly correlated variables
selected_var_mod <- varSel(reduced_var_mod, metric = 'tss', test = test,
                           bg4cor = cor.bg, method = 'spearman', cor_th = 0.7,
                           permut = 10, use_pc = T)

# env stack for downstream SDM operation ::: only containing selected env variables 
names(env_calib)
env_select <- stack(subset(env_calib, c(6,13,18,20,23,24,26,27)))
plot(env_select[[1]])
nlayers(env_select)
names(env_select)

#########################################################################################################################################
####################  use dismo 

#### first use ENMeval for parameter tuning
#### random k-fold partitioning
rand <- get.randomkfold(occs = occs[, c(2,3)], bg = targ.bg, k = 10) 
evalplot.grps(pts = occs[, c(2,3)], pts.grp = rand$occs.grp, envs = env_select[[1]])

#### run ENMevaluate
eval <- ENMevaluate(occs = occs[, c(2,3)],
                    envs = env_select,
                    bg = targ.bg,
                    tune.args = list(fc = c('L', 'LQ', 'H', 'LQH', 'LQHP', 'LQHPT'), rm = 0.5:8),
                    partitions = 'randomkfold',
                    partition.settings = list(kfolds = 10),
                    algorithm = 'maxent.jar',
                    doClamp = T)

#### select optimal parameter
eval.res <- eval.results(eval)

## optimal AICc
(opt.aicc <- eval.res %>% filter(delta.AICc == 0))  ##  == LQHP_4.5
mod.aicc <- eval.predictions(eval)[[opt.aicc$tune.args]]
plot(mod.aicc)

## sequential selection
(opt.seq <- eval.res %>% 
    filter(auc.val.avg == max(auc.val.avg)) %>%
    filter(or.10p.avg == min(or.10p.avg)))   ##  == H_0.5

mod.seq <- eval.predictions(eval)[[opt.seq$tune.args]]
plot(mod.seq)  

#### use sequentially selected model ::: H_0.5


#### dismo for model run ::: MaxEnt model fitting
## CAUTION for using args :::
## fully spell out [ true ] instead of [ T ] or [ TRUE ]
## and [ no space ] between flags and values
## for example ::: [ pictures=true ] instead of [ pictures = true ]
## for crossvalidation ::: set randomtestpoints to 0
dismo.mod <- dismo::maxent(x = env_select, p = occs[, c(2,3)], a = targ.bg, 
                           path = 'SDM/dismo', 
                           args = c('responsecurves=true',
                                    'pictures=true',
                                    'jackknife=true',
                                    'outputformat=cloglog',
                                    'outputfiletype=asc',
                                    'randomseed=true',
                                    'betamultiplier=0.5',
                                    'replicates=10',
                                    'randomtestpoints=0',
                                    'replicatetype=crossvalidate',
                                    'writebackgroundpredictions=true',
                                    'writeplotdata=true',
                                    'linear=false',
                                    'quadratic=false',
                                    'product=false',
                                    'threshold=false',
                                    'hinge=true',
                                    'visible=true',
                                    'autofeature=false',
                                    'outputgrids=true',
                                    'plots=true',
                                    'maximumiterations=5000'))


######## dismo ::: make MaxEnt model predictions
#### predict to calibration area
dismo.pred <- dismo::predict(object = dismo.mod, x = env_select)

## generate averaged model prediction
dismo.pred.avg <- mean(dismo.pred[[1]], dismo.pred[[2]], dismo.pred[[3]],
                       dismo.pred[[4]], dismo.pred[[5]], dismo.pred[[6]],
                       dismo.pred[[7]], dismo.pred[[8]], dismo.pred[[9]],
                       dismo.pred[[10]])

plot(dismo.pred.avg)

writeRaster(dismo.pred.avg, 'SDM/output_model_grids/calibration_area_avg_dismo.tif')

## plot ggplot style ::: continuous ::: calibration area
gplot(dismo.pred.avg) +
  geom_tile(aes(fill = value)) +
  coord_equal() +
  scale_fill_gradientn(colours = c("#2c7bb6", "#abd9e9", "#ffffbf", "#fdae61", "#d7191c"),
                       na.value = "transparent",
                       name = 'Suitability') +
  geom_polygon(data = mask, aes(x = long, y = lat, group = group), 
               color = 'black', fill = 'transparent', size = 1.0) +
  xlab('Longitude (°)') + ylab('Latitude (°)') + 
  theme_minimal() + 
  theme(axis.line = element_line(size = 1.0, colour = 'black'),
        axis.title = element_text(size = 14, face = 'bold'),
        axis.title.x = element_text(margin = margin(t = 20)),
        axis.title.y = element_text(margin = margin(r = 20)),
        axis.text = element_text(size = 12),
        legend.title = element_text(size = 14, face = 'bold', margin = margin(b = 10)),
        legend.text = element_text(size = 12))


######## predict to whole study extent
env_select2 <- raster::stack(subset(env, names(env_select)))
plot(env_select2[[1]])

dismo.pred2 <- dismo::predict(object = dismo.mod, x = env_select2)  

## generate averaged model prediction
dismo.pred2.avg <- mean(dismo.pred2[[1]], dismo.pred2[[2]], dismo.pred2[[3]],
                        dismo.pred2[[4]], dismo.pred2[[5]], dismo.pred2[[6]],
                        dismo.pred2[[7]], dismo.pred2[[8]], dismo.pred2[[9]],
                        dismo.pred2[[10]])

plot(dismo.pred2.avg)

writeRaster(dismo.pred2.avg, 'SDM/output_model_grids/full_area_avg_dismo.tif')


## plot ggplot style ::: continuous ::: whole area
## set font
windowsFonts(a = windowsFont('Times New Roman'))

gplot(dismo.pred2.avg) +
  geom_tile(aes(fill = value)) +
  coord_equal() +
  scale_fill_gradientn(colours = c('#2c7bb6', '#abd9e9', '#ffffbf', '#fdae61', '#d7191c'),
                       na.value = 'transparent',
                       name = 'Suitability') +
  geom_polygon(data = mask, aes(x = long, y = lat, group = group),
               color = 'black', fill = 'transparent', size = 1.0) +
  geom_polygon(data = buff, aes(x = long, y = lat, group = group),
               color = '#FF5722', fill = 'transparent', size = 1.7, 
               linetype = 1) +
  xlab('Longitude (°)') + ylab('Latitude (°)') + 
  theme_minimal() + 
  theme(text = element_text(family = 'a'),
        axis.title = element_text(size = 14, face = 'bold'),
        axis.title.x = element_text(margin = margin(t = 20)),
        axis.title.y = element_text(margin = margin(r = 20)),
        axis.text = element_text(size = 12),
        legend.title = element_text(size = 14, face = 'bold', margin = margin(b = 10)),
        legend.text = element_text(size = 12),
        panel.border = element_rect(fill = 'transparent', 
                                    color = 'black', size = 1.0))


###### generate binary grids :::  get value from MaxEnt result .csv file
## 10p threshold = 0.2578
## MTSS (test) threshold = 0.4154
bin.full.mod.10p <- ecospat::ecospat.binary.model(Pred = dismo.pred2.avg, Threshold = 0.2578)
bin.full.mod.mtss <- ecospat::ecospat.binary.model(Pred = dismo.pred2.avg, Threshold = 0.4154)

plot(bin.full.mod.10p)
plot(bin.full.mod.mtss)

writeRaster(bin.full.mod.10p, 'SDM/output_model_grids/bin.full.mod.10p.tif')
writeRaster(bin.full.mod.mtss, 'SDM/output_model_grids/bin.full.mod.mtss.tif')

###### but also check the survey presence threshold
survey.pres <- read.csv('occs/survey_presence.csv')
survey.pres <- thinData(coords = survey.pres, env = dismo.pred2.avg, x = 'long', y = 'lat')
head(survey.pres)

mod.pres.surv <- raster::extract(dismo.pred2.avg, survey.pres[, c(2,3)]) %>% as.data.frame()
head(mod.pres.surv)
min(mod.pres.surv)
nrow(mod.pres.surv)
sort(mod.pres.surv[[1]])

## survey 10p = 0.2177
## survey min pres = 0.0324
bin.min.pres <- ecospat::ecospat.binary.model(Pred = dismo.pred2.avg, Threshold = 0.0324)
bin.10p <- ecospat::ecospat.binary.model(Pred = dismo.pred2.avg, Threshold = 0.2177)

plot(bin.min.pres)
plot(bin.10p)

## plot ggplot style ::: binary ::: 10p
gplot(bin.full.mod.10p) + 
  geom_tile(aes(fill = value)) +
  coord_equal() +
  scale_fill_gradientn(colors = c('lightgrey', '#1E88E5'),
                       na.value = 'transparent') +
  geom_polygon(data = mask, aes(x = long, y = lat, group = group), 
               fill = 'transparent', color = 'black', size = 1.0) +
  geom_polygon(data = buff, aes(x = long, y = lat, group = group),
               fill = 'transparent', color = '#FF5722', size = 1.7,
               linetype = 1) +
  xlab('Longitude (°)') + ylab('Latitude (°)') + 
  theme_minimal() + 
  theme(text = element_text(family = 'a'),
        axis.title = element_text(size = 14, face = 'bold'),
        axis.title.x = element_text(margin = margin(t = 20)),
        axis.title.y = element_text(margin = margin(r = 20)),
        axis.text = element_text(size = 12),
        legend.position = 'none',
        panel.border = element_rect(fill = 'transparent', 
                                    color = 'black', size = 1.0)) 
 

## plot ggplot style ::: binary ::: mtss (test)
gplot(bin.full.mod.mtss) +
  geom_tile(aes(fill = value)) +
  coord_equal() + 
  scale_fill_gradientn(colors = c('lightgrey', '#1E88E5'),
                       na.value = 'transparent') +
  geom_polygon(data = mask, aes(x = long, y = lat, group = group),
               fill = 'transparent', color = 'black', size = 1.0) +
  geom_polygon(data = buff, aes(x = long, y = lat, group = group),
               fill = 'transparent', color = '#FF5722', size = 1.7,
               linetype = 1) +
  xlab('Longitude (°)') + ylab('Latitude (°)') + 
  theme_minimal() + 
  theme(text = element_text(family = 'a'),
        axis.title = element_text(size = 14, face = 'bold'),
        axis.title.x = element_text(margin = margin(t = 20)),
        axis.title.y = element_text(margin = margin(r = 20)),
        axis.text = element_text(size = 12),
        legend.position = 'none',
        panel.border = element_rect(fill = 'transparent', 
                                    color = 'black', size = 1.0))


## plot ggplot style ::: in rasterStack ::: side-by-side mapping
bin.stack <- raster::stack(bin.full.mod.10p, bin.full.mod.mtss)  
names(bin.stack) <- c('P10', 'MTSS')

gplot(bin.stack) +
  geom_tile(aes(fill = value)) + 
  facet_wrap(~ variable) + 
  coord_equal() + 
  scale_fill_gradientn(colors = c('lightgrey', '#1E88E5'),
                       na.value = 'transparent') +
  geom_polygon(data = mask, aes(x = long, y = lat, group = group),
               fill = 'transparent', color = 'black', size = 1.0) +
  geom_polygon(data = buff, aes(x = long, y = lat, group = group),
               fill = 'transparent', color = '#FF5722', size = 1.7,
               linetype = 1) +
  xlab('Longitude (°)') + ylab('Latitude (°)') + 
  theme_bw() + 
  theme(text = element_text(family = 'a'),
        axis.title = element_text(size = 14, face = 'bold'),
        axis.title.x = element_text(margin = margin(t = 20)),
        axis.title.y = element_text(margin = margin(r = 20)),
        axis.text = element_text(size = 12),
        strip.text = element_text(size = 14),
        legend.position = 'none')


#############  evaluate models
#####  calculate TSS  ###############
### Calculate TSS (True Skill Statistic)
### to be able to run this script you need to have told the Maxent model to produce background predictions. 
### If you are running MaxEnt in R this means putting the argument (after "args") 
### "writebackgroundpredictions=true" as true not false. 

list.files('SDM/dismo')

#read in the file 
backgroundpredictions <- read.csv('SDM/dismo/species_9_backgroundPredictions.csv')

#we need the last column so will set the number as x
x <- length(backgroundpredictions)

#extract the cloglog/logistic results
backgroundclog <- backgroundpredictions[,x]

#now read in the sample predictions for testing
samplepredictions <- read.csv("SDM/dismo/species_9_samplePredictions.csv")

#we need the last column again of logistic or cloglog predictions so set a second x
x2 <- length(samplepredictions)

#extract the cloglog/logistic results for sample
sampleclog <- samplepredictions[,x2]

#set n the number of pseuabsences used for backgroudn predictions by MaxEnt
n <- 10000

#set threshold value
th <- 0.4154

TSS_calculations <- function(sampleclog, backgroundclog, n, th) {
  
  xx <- sum(sampleclog > th)
  yy <- sum(backgroundclog > th)
  xxx <- sum(sampleclog < th)
  yyy <- sum(backgroundclog < th)
  
  ncount <- sum(xx,yy,xxx,yyy)
  
  overallaccuracy <- (xx + yyy)/ncount 
  sensitivity <- xx / (xx + xxx)
  specificity <- yyy / (yy + yyy)
  tss <- sensitivity + specificity - 1
  
  #kappa calculations
  a <- xx + xxx
  b <- xx + yy
  c <- yy + yyy
  d <- xxx + yyy
  e <- a * b
  f <- c * d
  g <- e + f
  h <- g / (ncount * ncount)
  hup <- overallaccuracy - h
  hdown <- 1 - h
  
  kappa <- hup/hdown
  Po <- (xx + yyy) / ncount
  Pe <- ((b/ncount) * (a/ncount)) + ((d/ncount) * (c/ncount))
  Px1 <- Po - Pe
  Px2 <- 1 - Pe
  Px3 <- Px1/Px2
  
  tx1 <- xx + yyy
  tx2 <- 2 * a * c
  tx3 <- a - c
  tx4 <- xx - yyy
  tx5 <- ncount * (( 2 * a ) - tx4)
  tx6 <- ncount * tx1
  
  kappamax <- (tx6 - tx2 - (tx3 * tx4)) / ((tx5 - tx3) - (tx3 * tx4))
  
  cat(" Maxent results for model with\n",a,"test sample predictions\n",c ,
      "background predicitons\n\n TSS value:        ", 
      tss,"\n Overall accuracy: ",overallaccuracy,"\n Sensitivity:      ",
      sensitivity,"\n Specificity:      ",specificity,"\n Kappa:            ",
      kappa,"\n Kappa max:        ",kappamax)
  
  
}


#run the function, the input values are the sampleclog values, 
#then the background clog values, 
#the sample number for the pseudo absences and then threshold value

TSS_calculations(sampleclog,backgroundclog,n,th)



## calculate average TSS +- sd: mtss

a <- 0.5453 + 0.5562 + 0.5640 + 0.5470 + 0.5489 + 0.5637 + 0.5612 + 0.5496 + 0.5562 + 0.5393
a/10

b <- c(0.5453, 0.5562, 0.5640, 0.5470, 0.5489, 0.5637, 0.5612, 0.5496, 0.5562, 0.5393)
sd(b)





#####  null models ::: 100 iterations   ##########
mod.null <- ENMnulls(eval, mod.settings = list(fc = 'H', rm = 0.5), no.iter = 100)
null.res <- null.results(mod.null)
null.algorithm(mod.null)

head(null.res$auc.val.avg)
mean(null.res$auc.val.avg)

evalplot.nulls(mod.null, stats = c('auc.val', 'or.10p'), plot.type = 'histogram')


## plot auc.val of empirical & null models
# make data
head(eval.res$auc.val.avg)
head(null.res$auc.val.avg)

emp.auc <- as.data.frame(eval.res$auc.val.avg)
emp.auc$type <- 'Empirical'
colnames(emp.auc) = c('AUC', 'type')
head(emp.auc)

null.auc <- as.data.frame(null.res$auc.val.avg)
null.auc$type <- 'Null'
colnames(null.auc) = colnames(emp.auc)
head(null.auc)

auc <- rbind(emp.auc, null.auc)  

# plot
auc %>%
  ggplot(aes(x = type, y = AUC, fill = type, group = type)) + 
  geom_boxplot(size = 1.2, width = 0.5) +
  xlab('Model') + 
  ylab('Test AUC') +
  theme(text = element_text(family = 'a'),
        panel.border = element_rect(size = 1.0, fill = 'transparent'),
        legend.position = 'none',
        axis.title = element_text(size = 14, face = 'bold'),
        axis.title.x = element_text(margin = margin(t = 20)),
        axis.title.y = element_text(margin = margin(r = 20)),
        axis.text = element_text(size = 12),
        axis.text.x = element_text(margin = margin(t = 8)),
        axis.text.y = element_text(margin = margin(r = 8)))

# statistical comparisons
head(emp.auc)
histogram(emp.auc[[1]])
shapiro.test(emp.auc[[1]])

head(null.auc)
histogram(null.auc[[1]])
shapiro.test(null.auc[[1]])

wilcox.test(x = emp.auc[[1]], y = null.auc[[1]])


########  plot response curves  ###########
## read plot data
bio3 <- read.csv('SDM/resp_csv/species_wc2.1_30s_bio_3.csv')
bio8 <- read.csv('SDM/resp_csv/species_wc2.1_30s_bio_8.csv')
bio14 <- read.csv('SDM/resp_csv/species_wc2.1_30s_bio_14.csv')
cultivated <- read.csv('SDM/resp_csv/species_cultivated.csv')
herb <- read.csv('SDM/resp_csv/species_herb.csv')
water <- read.csv('SDM/resp_csv/species_open_water.csv')
slope <- read.csv('SDM/resp_csv/species_slope_1km.csv')
urban <- read.csv('SDM/resp_csv/species_urban.csv')

head(bio3)
head(bio8)
head(bio14)
head(cultivated)
head(herb)
head(water)
head(slope)
head(urban)

## combine & recode
resp <- rbind(bio3, bio8, bio14, cultivated, herb, water, slope, urban)
resp$variable <- recode_factor(resp$variable,
                               'wc2.1_30s_bio_3' = 'Bio 3',
                               'wc2.1_30s_bio_8' = 'Bio 8',
                               'wc2.1_30s_bio_14' = 'Bio 14',
                               'cultivated' = 'Cultivated',
                               'herb' = 'Herbaceous',
                               'open_water' = 'Open water',
                               'slope_1km' = 'Slope',
                               'urban' = 'Urban area')

head(resp)
tail(resp)

## plot
min <- resp$y - sd(resp$y, na.rm = T) # sd
max <- resp$y + sd(resp$y, na.rm = T) # sd

resp$variable = factor(resp$variable, 
                        levels = c('Bio 3', 'Bio 8', 'Bio 14', 'Slope', 'Cultivated',
                                   'Herbaceous', 'Open water', 'Urban area'))

resp %>%
  ggplot(aes(x = x, y = y)) +
  #geom_ribbon(aes(ymin = min, ymax = max), fill = 'lightgrey') +
  geom_line(size = 1.2, color = '#1976D2') +
  facet_wrap(~ variable, nrow = 2, ncol = 4, scales = 'free_x') +
  xlab('Value') + ylab('Suitability') +
  theme_bw() + 
  theme(text = element_text(family = 'a'),
        axis.title = element_text(size = 16, face = 'bold'),
        axis.title.x = element_text(margin = margin(t = 20)),
        axis.title.y = element_text(margin = margin(r = 20)),
        axis.text = element_text(size = 12),
        strip.text = element_text(size = 14))
  
