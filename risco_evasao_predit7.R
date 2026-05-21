# AJUSTE DE MODELO PARA EVITAR data leakage

# Função de limpeza ultra-agressiva
# =====================================================
# 1. Bibliotecas
# =====================================================
if(!require(openxlsx)) install.packages("openxlsx")
install.packages("pROC")
library(pROC)
library(tidyverse)
library(caret)
library(randomForest)
library(readxl)
library(janitor)
library(stringi)
library(openxlsx)

# Função de Limpeza (Para garantir que Sexo, Turno etc. fiquem padronizados)
limpar_texto_modelo <- function(x) {
  if(is.character(x)) {
    x <- str_trim(x) 
    x <- stri_trans_general(x, "Latin-ASCII")
    x <- str_to_lower(x) 
  }
  return(x)
}

# =====================================================
# 2. Dados de Treino (2023-2026)
# =====================================================
dados_predit <- read_excel("C:/Users/acer/OneDrive/Documentos/UTFPR/ASGRAD/Projeto_Python/DESISTENTESeFORMADOS_2023_2026.xlsx") %>%
  clean_names() %>%
  na.omit() %>%
  mutate(across(where(is.character), limpar_texto_modelo))

# Recodificar variável resposta para nomes válidos
dados_predit$situacao_atual <- fct_recode(factor(dados_predit$situacao_atual),
                                   formado = "formado",
                                   desistente = "desistente/desligado")

# Conferir distribuição
print(table(dados_predit$situacao_atual))

# =====================================================
# 3. Divisão treino/teste
# =====================================================
set.seed(123)
trainIndex <- createDataPartition(dados_predit$situacao_atual, p = 0.7, list = FALSE)
train <- dados_predit[trainIndex, ]
test  <- dados_predit[-trainIndex, ]

# =====================================================
# 3. Pré-processamento numérico
# =====================================================
num_vars <- c("coeficiente_de_rendimento_absoluto",
              "nr_disciplinas_reprovadas_por_nota",
              "nr_disciplinas_reprovadas_por_frequencia",
              "nr_disciplinas_aprovadas",
              "total_de_semestres_cursados",
              "total_de_semestres_do_curso")

preproc <- preProcess(train[, num_vars], method = c("center", "scale"))
train_pp <- predict(preproc, train)
test_pp  <- predict(preproc, test)

# Criar variáveis derivadas
criar_variaveis <- function(df) {
  df %>%
    mutate(
      taxa_reprovacao = coalesce((nr_disciplinas_reprovadas_por_nota + nr_disciplinas_reprovadas_por_frequencia) / (nr_disciplinas_aprovadas + 1), 0),
      tempo_no_curso = coalesce(total_de_semestres_cursados / total_de_semestres_do_curso, 0)
    )
}
train_pp <- criar_variaveis(train_pp)
test_pp  <- criar_variaveis(test_pp)

# =====================================================
# 4. Padronizar fatores com nível "outros"
# =====================================================
cols_cat <- c("sexo", "forma_de_ingresso", "tipo_de_cota", "turno")

for(col in cols_cat){
  # treino: garantir que "outros" exista
  train_pp[[col]] <- factor(train_pp[[col]])
  if(!("outros" %in% levels(train_pp[[col]]))) {
    levels(train_pp[[col]]) <- c(levels(train_pp[[col]]), "outros")
}
  
  # teste: mapear níveis desconhecidos para "outros"
  test_pp[[col]] <- fct_other(factor(test_pp[[col]]),
                              keep = levels(train_pp[[col]]),
                              other_level = "outros")
}

# =====================================================
# 5. Treinamento
# =====================================================
ctrl <- trainControl(method = "cv", number = 5,
                     classProbs = TRUE,
                     summaryFunction = twoClassSummary,
                     sampling = "up")

set.seed(123)
modelo_evasao <- train(
  situacao_atual ~ sexo + coeficiente_de_rendimento_absoluto +
    taxa_reprovacao + tempo_no_curso +
    forma_de_ingresso + tipo_de_cota + turno,
  data = train_pp,
  method = "rf",
  trControl = ctrl,
  metric = "ROC",
  tuneLength = 3
)

# =====================================================
# 6. Avaliação
# =====================================================
pred_prob <- predict(modelo_evasao, test_pp, type = "prob")
roc_obj <- roc(test_pp$situacao_atual, pred_prob[,"desistente"])
plot(roc_obj, col = "blue")

confusionMatrix(predict(modelo_evasao, test_pp), test_pp$situacao_atual)


# Importância das variáveis com caret
importancia <- varImp(modelo_evasao, scale = TRUE)

# Visualizar tabela
print(importancia)

# Gráfico
plot(importancia, top = 10)   # mostra as 10 variáveis mais importantes


# =====================================================
# 7. Aplicar nos ativos (SOLUÇÃO FINAL - REESTRUTURADA)
# =====================================================

# 1. Leitura Limpa
ativos_original <- read_excel("C:/Users/acer/OneDrive/Documentos/UTFPR/ASGRAD/Projeto_Python/REGULARES_2023_2026.xlsx") %>%
  clean_names()

# 2. Criar as variáveis de análise (Valores Reais para o Excel)
# Criamos aqui para que elas existam na planilha final sem normalização
ativos_original <- ativos_original %>%
  mutate(
    taxa_reprovacao = coalesce((nr_disciplinas_reprovadas_por_nota + nr_disciplinas_reprovadas_por_frequencia) / (nr_disciplinas_aprovadas + 1), 0),
    tempo_no_curso = coalesce(total_de_semestres_cursados / total_de_semestres_do_curso, 0)
  )

# 3. Preparar Cópia para o Modelo
# Vamos limpar o texto e sincronizar os fatores primeiro
ativos_para_modelo <- ativos_original %>% 
  mutate(across(where(is.character), limpar_texto_modelo))

for(col in cols_cat){
  ativos_para_modelo[[col]] <- fct_other(factor(ativos_para_modelo[[col]]),
                                         keep = levels(train_pp[[col]]),
                                         other_level = "outros")
}

# 4. APLICAÇÃO DA NORMALIZAÇÃO (O Ponto Crítico)
# O predict(preproc) vai transformar 'coeficiente_de_rendimento_absoluto' em Z-score
# Mas ele NÃO vai mexer no 'tempo_no_curso' porque ela não estava no treino original
ativos_para_modelo_norm <- predict(preproc, ativos_para_modelo)

# 5. Gerar Predições
prob_ativos <- predict(modelo_evasao, ativos_para_modelo_norm, type = "prob")[,"desistente"]

# 6. Montagem da Planilha Final (Unindo o Útil ao Agradável)
# Criamos um novo dataframe para garantir que nada seja sobrescrito
resultado_final <- ativos_original

# Adicionamos os resultados do modelo
resultado_final$probabilidade_desistencia <- as.numeric(prob_ativos)
resultado_final$risco_final <- ifelse(prob_ativos >= 0.7, "ALERTA", "ESTAVEL")

# Adicionamos o CRZscore (pegando o valor transformado do objeto de modelo)
# Aqui aparecerão os valores negativos (ex: -0.5, -1.2)
resultado_final$cr_zscore_modelo <- ativos_para_modelo_norm$coeficiente_de_rendimento_absoluto

# 7. Exportação
write.xlsx(resultado_final, "Predicao_Evasao_2023_2026_8.xlsx", overwrite = TRUE)

print("Verificação Concluída! Cheque a coluna 'cr_zscore_modelo' para negativos e 'tempo_no_curso' para decimais positivos.")