

setwd(dirname(rstudioapi::getSourceEditorContext()$path))


# Simulation of a discretized logit model
set.seed(1)
x = matrix(runif(300), nrow = 100, ncol = 3)
cuts = seq(0,1,length.out= 4)
xd = apply(x,2, function(col) as.numeric(cut(col,cuts)))
theta = t(matrix(c(0,0,0,2,2,2,-2,-2,-2),ncol=3,nrow=3))
log_odd = rowSums(t(sapply(seq_along(xd[,1]), function(row_id) sapply(seq_along(xd[row_id,]),
                                                                      function(element) theta[xd[row_id,element],element]))))
y = rbinom(100,1,1/(1+exp(-log_odd)))


library(tikzDevice)

predictors = x
labels = y
criterion = 'bic'

m_start = 5
iter = 300


prop.table.robust = function(x, margin = NULL) {
     tab <- sweep(x, margin, margin.table(x, margin), "/", check.margin = FALSE)
     tab[which(is.na(tab))] <- 1/ncol(tab)
     tab
}


noms_colonnes = colnames(predictors)

# Cas complets
continu_complete_case = !is.na(predictors)

# Calculating lengths n and d and data types
n = length(labels)
d = length(predictors[1,])
types_data <- sapply(predictors[1,], class)

if (sum(!(types_data %in% c("numeric","factor")))>0) {
     stop(simpleError("Unsupported data types. Columns of predictors must be numeric or factor."))
}

# Initializing list of calculated criterion among which to select the best.
criterion_iter=list()

# Initializing variable E (discretization of X) at random.
e = emap = array(0,c(n,d))
for (j in which(types_data=="numeric")) {
     e[continu_complete_case[,j],j] = emap[continu_complete_case[,j],j] = as.factor(sample(1:m_start,sum(continu_complete_case[,j]),replace = TRUE))
     e[!continu_complete_case[,j],j] = emap[!continu_complete_case[,j],j] = m_start+1
}
for (j in which(types_data=="factor")) {
     # e[continu_complete_case[,j],j] = emap[continu_complete_case[,j],j] = as.factor(sample(1:nlevels(predictors[,j]),n,replace = TRUE))
     # e[!continu_complete_case[,j],j] = emap[!continu_complete_case[,j],j] = nlevels(predictors[,j])+1
     e[,j] = emap[,j] = as.factor(sample(1:nlevels(predictors[,j]),n,replace = TRUE))
}

m = rep(m_start,d)
m[which(types_data=="numeric")] = as.vector(apply(e[,which(types_data=="numeric")],2,function(col) nlevels(factor(col))))
m[which(types_data=="factor")] = as.vector(apply(e[,which(types_data=="factor")],2,function(col) nlevels(factor(col))))
names(m) <- paste("X", 1:length(m), sep = "")
lev = apply(e,2,function(col) list(levels(factor(col))))

# Initializing "current" best logistic regression and link functions.
current_best = 1
best_reglog = 0
best_link = 0



# SEM algorithm
for (i in 1:iter){
     
     # if (sum(elementwise.all.equal(m,1))==d) {stop("Early stopping rule: all variables discretized in one value")}
     
     data_e = Filter(function(x)(length(unique(x))>1),data.frame(apply(e,2,factor)))
     data_emap = Filter(function(x)(length(unique(x))>1),data.frame(apply(emap,2,factor)))
     data = data.frame(e,labels = labels)
     data_logit = data.frame(emap,labels = labels)
     

          
     fmla = stats::as.formula(paste("~",paste(colnames(data_e),collapse = "+")))
     fmla_logit = stats::as.formula(paste("~",paste(colnames(data_emap),collapse = "+")))
     
     data = stats::model.matrix(fmla, data = data_e)
     data_logit = stats::model.matrix(fmla_logit, data = data_emap)
     
     model_reglog = RcppNumerical::fastLR(data_logit,labels)
     
     logit = RcppNumerical::fastLR(data,labels)
     
     
     # Calculate current performance and update (if better than previous best) current best model.
     criterion_iter[[i]] = 2*model_reglog$loglikelihood-log(n)*length(model_reglog$coefficients)

     if (criterion_iter[[i]] >= criterion_iter[[current_best]]) {
          best_reglog = model_reglog
          best_link = tryCatch(link,error=function(cond) list())
          current_best = i
          best_formula = fmla_logit
     }
     
     # Initialization of link function
     link=list()
     lev_1 = lev
     m = apply(e,2,function(el) nlevels(as.factor(el)))
     
     # Update E^j with j chosen at random
     for (j in sample(1:d)) {
          
          # p(e^j | x^j) training
          if (length(unique(e[continu_complete_case[,j],j]))>1) {
               
               if (sum(lapply(lapply(1:d,function(j) !lev_1[[j]][[1]] %in% lev[[j]][[1]]),sum)>0)>0) {
                    e[,which(lapply(lapply(1:d,function(j) !lev_1[[j]][[1]] %in% lev[[j]][[1]]),sum)>0)] = sapply(which(lapply(lapply(1:d,function(j) !lev_1[[j]][[1]] %in% lev[[j]][[1]]),sum)>0), function(col) factor(e[,col],levels = lev_1[[col]][[1]]))
               }
               
               # Polytomic or ordered logistic regression
               if ((types_data[j]=="numeric")) {
                    link[[j]] = nnet::multinom(e ~ x, data=data.frame(e=e[continu_complete_case[,j],j],x=predictors[continu_complete_case[,j],j]), start = link[[j]]$coefficients, trace = FALSE, Hess=FALSE, maxit=50)
               }
          }
          
          # p(y|e^j,e^-j) calculation
          if ((m[j])>1) {
               y_p = array(0,c(n,(m[j])))
               levels_to_sample <- unlist(lev[[j]][[1]])
               
               for (k in 1:length(levels_to_sample)) {
                    modalites_k = data
                    
                    if (j>1) {
                         modalites_k[,((3-j+sum((m[1:(j-1)]))):(1-j+sum((m[1:j]))))] = matrix(0,nrow=n,ncol=m[j]-1)
                    } else {
                         modalites_k[,(2:((m[1])))] = matrix(0,nrow=n,ncol=(m[j])-1)
                    }
                    
                    if (paste0("X",j,as.numeric(levels_to_sample[k])) %in% colnames(data)) {
                         modalites_k[,paste0("X",j,as.numeric(levels_to_sample[k]))] = rep(1,n)
                    }
                    
                    p = predictlogisticRegression(modalites_k,logit$coefficients)
                    
                    y_p[,k] <- (labels*p+(1-labels)*(1-p))
               }
               
               # p(e^j|reste) calculation
               if ((types_data[j]=="numeric")) {
                    
                    
                    t = predict(link[[j]], newdata = data.frame(x = predictors[continu_complete_case[,j],][,j]),type="probs")
                    
                    if (is.vector(t)) {
                         t = cbind(1-t,t)
                         colnames(t) = c("1","2")
                    }
                    
                    if (sum(!continu_complete_case[,j])>0) {
                         t_bis = matrix(NA,nrow = nrow(predictors), ncol = ncol(t) +1)
                         t_bis[continu_complete_case[,j],1:ncol(t)] = t
                         t_bis[continu_complete_case[,j],ncol(t)+1] = 0
                         t_bis[!continu_complete_case[,j],] = t(matrix(c(rep(0,ncol(t)),1),nrow = ncol(t)+1,ncol=sum(!continu_complete_case[,j])))
                         colnames(t_bis) = c(colnames(t),m_start+1)
                         t = t_bis
                    }
                    
               } else {
                    link[[j]] = table(e[,j],predictors[,j])
                    t = prop.table.robust(t(sapply(predictors[,j],function(row) link[[j]][,row])),1)
               }
               
               # Updating emap^j
               emap[,j] <- apply(t,1,function(p) names(which.max(p)))
               
               t <- prop.table.robust(t*y_p,1)
               
               e[,j] <- apply(t,1,function(p) sample(levels_to_sample,1,prob = p,replace = TRUE))
               
               
               if (nlevels(as.factor(e[,j]))>1) {
                    if (nlevels(as.factor(e[,j]))==m[j]) {
                         if (j>1) {
                              data[,((3-j+sum((m[1:(j-1)]))):(1-j+sum((m[1:j]))))] = stats::model.matrix(stats::as.formula("~e"),data=data.frame("e"=factor(e[,j])))[,-1]
                         } else {
                              data[,(2:(m[1]))] = stats::model.matrix(stats::as.formula("~e"),data=data.frame("e"=factor(e[,j])))[,-1]
                         }
                    } else {
                         if (which(!lev[[j]][[1]] %in% levels(as.factor(e[,j])))[1]>1) {
                              
                              data[,paste0("X",j,lev[[j]][[1]][which(!lev[[j]][[1]] %in% levels(as.factor(e[,j])))])] <- matrix(0,nrow = n, ncol = sum(!lev[[j]][[1]] %in% levels(as.factor(e[,j]))))
                              data[,paste0("X",j,levels(as.factor(e[,j])))[paste0("X",j,levels(as.factor(e[,j]))) %in% colnames(data)]] <- stats::model.matrix(stats::as.formula("~e[,j]"),data=data.frame(e[,j]))[,-1]
                              
                         } else {
                              
                              if (length(which(!lev[[j]][[1]] %in% levels(as.factor(e[,j]))))>1) {
                                   data[,paste0("X",j,lev[[j]][[1]][which(!lev[[j]][[1]] %in% levels(as.factor(e[,j])))[-1]])] <- matrix(0,nrow = n, ncol = sum(!lev[[j]][[1]] %in% levels(as.factor(e[,j]))))
                              }
                              
                              reste <- stats::model.matrix(stats::as.formula("~e[,j]"),data=data.frame(e[,j]))[,-1]
                              data[,paste0("X",j,levels(as.factor(e[,j])))[paste0("X",j,levels(as.factor(e[,j]))) %in% colnames(data)]][,-1] <- reste
                              if (nlevels(as.factor(e[,j]))==2) {
                                   data[,paste0("X",j,levels(as.factor(e[,j])))[paste0("X",j,levels(as.factor(e[,j]))) %in% colnames(data)]][,1] <- as.numeric(reste==0)
                              } else {
                                   data[,paste0("X",j,levels(as.factor(e[,j])))[paste0("X",j,levels(as.factor(e[,j]))) %in% colnames(data)]][,1] <- as.numeric(rowSums(reste)==0)
                              }
                         }
                    }
               } else {
                    data[,paste0("X",j,lev[[j]][[1]][which(!lev[[j]][[1]] %in% levels(as.factor(e[,j])))])] <- matrix(0,nrow = n, ncol = sum(!lev[[j]][[1]] %in% levels(as.factor(e[,j]))))
               }
               
          } else {
               # e^j and emap^j for disappearing features
               e[,j] <- emap[,j] <- factor(rep(1,n))
               
          }
          
          tikz(paste0('sem_simulated_data/sem_feature_',j,'_iter_',i,'.tex'), standAlone=FALSE, width = 4, height = 3, fg = "white")
          plot(predictors[,j],e[,j], xlab = '$x_j$', ylab = '$e_j$', col = e[,j])
          dev.off()
     }
     lev <- apply(e,2,function(col) list(levels(factor(col))))
     
     message("Iteration ",i," ended with a performance of ",criterion," = ", criterion_iter[[i]])
     
}


