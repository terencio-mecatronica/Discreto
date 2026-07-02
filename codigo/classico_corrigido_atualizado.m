%% 1. IMPORTAÇÃO, FILTRAGEM E IDENTIFICAÇÃO DINÂMICA
clear; clc; close all;

% -------------------------------------------------------------------
% Caminhos do projeto
% -------------------------------------------------------------------
% O script pode ficar na raiz do projeto ou dentro da pasta "codigo".
% A pasta "dados" deve conter:
% - tef_ft_170.txt
% - sem carga (1).zip
% - com carga.zip
% - dados_sem_carga.zip       -> Ziegler-Nichols sem carga
% - dados_com_carga.zip       -> Ziegler-Nichols com carga

pasta_script = fileparts(mfilename('fullpath'));

if isempty(pasta_script)
    pasta_script = pwd;
end

if isfolder(fullfile(pasta_script, 'dados'))
    pasta_projeto = pasta_script;
elseif isfolder(fullfile(fileparts(pasta_script), 'dados'))
    pasta_projeto = fileparts(pasta_script);
else
    pasta_projeto = pasta_script;
end

pasta_dados = fullfile(pasta_projeto, 'dados');

nome_arquivo = fullfile(pasta_dados, 'tef_ft_170.txt');

% Compatibilidade: se o arquivo de identificação estiver como "dados.txt"
if ~isfile(nome_arquivo)
    nome_arquivo_alt = fullfile(pasta_dados, 'dados.txt');

    if isfile(nome_arquivo_alt)
        nome_arquivo = nome_arquivo_alt;
    end
end

if ~isfile(nome_arquivo)
    error('Arquivo de identificação não encontrado: %s', nome_arquivo);
end

linhas = readlines(nome_arquivo);
t_ms = []; y_adc = [];

for i = 1:length(linhas)
    if contains(linhas(i), '->')
        partes = split(linhas(i), '->');
        valores = split(strtrim(partes(2)), ',');
        if length(valores) == 2
            tempo = str2double(valores(1));
            adc = str2double(valores(2));
            if ~isnan(tempo) && ~isnan(adc)
                t_ms = [t_ms; tempo];
                y_adc = [y_adc; adc];
            end
        end
    end
end

% Sincronização e translação para a origem (0,0)
t = t_ms / 1000;
idx_degrau = find(y_adc > 0, 1, 'first');

t = t(idx_degrau:end) - t(idx_degrau); 
y_adc = y_adc(idx_degrau:end);

% ============================================================
% FILTRAGEM ROBUSTA PARA BANCADA COM RUÍDO
% ============================================================

% 1) Remove picos isolados do sensor
y_filtrado = movmedian(y_adc, 5);

% 2) Suaviza o sinal mantendo a tendência da resposta
y_filtrado = movmean(y_filtrado, 15);

% 3) Remoção de offset inicial
offset = y_filtrado(1);

y_filtrado = y_filtrado - offset;
y_adc = y_adc - offset;

% 4) Evita valores negativos depois da remoção do offset
y_filtrado = max(0, y_filtrado);
y_adc = max(0, y_adc);

% ============================================================
% EXTRAÇÃO AUTOMÁTICA DE K E TAU
% ============================================================

degrau_in = 170;

% Média dos últimos pontos para estimar o valor final
idx_media = max(1, length(y_filtrado) - 50); 
y_ss = mean(y_filtrado(idx_media:end));

% Ganho estático
K = y_ss / degrau_in;

% Constante de tempo: tempo em que atinge 63,2% do valor final
idx_tau = find(y_filtrado >= (0.632 * y_ss), 1, 'first');

if isempty(idx_tau)
    warning('Não foi possível encontrar tau automaticamente. Verifique o sinal filtrado.');
    tau = NaN;
else
    tau = t(idx_tau);
end

Ts = 0.1;

fprintf('=== Parâmetros Calculados Dinamicamente ===\n');
fprintf('Ganho Estático Total (K): %.4f\n', K);
fprintf('Constante de Tempo (Tau): %.4f s\n\n', tau);

%% 3. MODELAGEM MATEMÁTICA DOS ELEMENTOS (REQUISITO DO ROTEIRO)
s = tf('s');
Ts = 0.1; % Período de amostragem (100 ms)

% -------------------------------------------------------------------
% A. Modelos Matemáticos dos Demais Elementos (Figura 1)
% -------------------------------------------------------------------
% VALORES ATUALIZADOS CONFORME A TABELA DA BANCADA:
Ka = 3.5 / 100;       % Ganho do Atuador (0 a 100% -> 0 a 3.5V)
Ks = 100 / 1750;      % Ganho do Sensor (0 a 1750 RPM -> 0 a 100%)
Km = K / (Ka * Ks);   % Ganho deduzido do Motor (RPM/V)

G_atuador = tf(Ka, 1);
G_sensor  = tf(Ks, 1);
G_motor   = Km / (tau * s + 1);

disp('--- A. Elementos Individuais do Diagrama (Figura 1) ---');
disp('1. Modelo do Atuador G_a(s):'); 
G_atuador
disp('2. Modelo do Processo (Motor) G_m(s):'); 
G_motor
disp('3. Modelo do Sensor H_s(s):'); 
G_sensor

% -------------------------------------------------------------------
% B. Modelos de Malha Aberta
% -------------------------------------------------------------------
% A Malha Aberta é a cascata: Atuador * Motor * Sensor
G_ma_s = G_atuador * G_motor * G_sensor;
G_ma_z = c2d(G_ma_s, Ts, 'zoh');

disp('--- B. Sistema em Malha Aberta ---');
disp('Malha Aberta Contínua G_MA(s):'); 
G_ma_s
disp('Malha Aberta Discreta G_MA(z):'); 
G_ma_z

% -------------------------------------------------------------------
% C. Modelos de Malha Fechada (Com e Sem Controlador)
% -------------------------------------------------------------------

% 1. Malha Fechada SEM Controlador
% Calculamos tanto para o mundo analógico (s) quanto para o digital (z)
FT_mf_sem_ctrl_s = feedback(G_ma_s, 1);
FT_mf_sem_ctrl_z = feedback(G_ma_z, 1);

disp('--- C. Sistema em Malha Fechada ---');
disp('1. Malha Fechada SEM Controlador FT(s) [Analógico]:'); 
FT_mf_sem_ctrl_s

disp('2. Malha Fechada SEM Controlador FT(z) [Digital - Equação da Imagem]:'); 
FT_mf_sem_ctrl_z

%% 4. ANÁLISE GRÁFICA COMPARATIVA
figure('Name', 'Validação do Modelo', 'Color', 'w');
plot(t, y_adc, 'Color', [0.8 0.8 0.8], 'DisplayName', 'Sinal Bruto'); hold on;
plot(t, y_filtrado, 'b', 'LineWidth', 1.5, 'DisplayName', 'Sinal Filtrado');

[y_sim, t_sim] = step(degrau_in * G_ma_s, t);
plot(t_sim, y_sim, 'r--', 'LineWidth', 2, 'DisplayName', 'Modelo G(s)');

title('Validação do Modelo: Planta Real x Equação Matemática');
xlabel('Tempo (s)'); ylabel('ADC (0 a 1023)');
legend('Location', 'southeast'); grid on;

%% 5. PROJETO DOS MÉTODOS DE CONTROLE (PI)
% Parâmetro extra necessário para os métodos empíricos:
L = 0.6; % Tempo Morto (Atraso de transporte) estimado em segundos

% Métodos de discretização usados para TODOS os controladores PI
metodos_disc = struct();
metodos_disc(1).id = 'tustin';
metodos_disc(1).nome = 'Tustin (Trapezoidal)';

metodos_disc(2).id = 'forward';
metodos_disc(2).nome = 'Euler Progressivo';

metodos_disc(3).id = 'backward';
metodos_disc(3).nome = 'Euler Regressivo';

disp('--- Calculando os métodos de controle PI ---');

% -------------------------------------------------------------------
% Ganhos contínuos dos controladores PI
% -------------------------------------------------------------------
controladores = struct();

% -------------------------------------------------------------------
% Métodos de discretização usados para todos os controladores PI
% -------------------------------------------------------------------
metodos_disc = struct();

metodos_disc(1).id = 'tustin';
metodos_disc(1).nome = 'Tustin';

metodos_disc(2).id = 'forward';
metodos_disc(2).nome = 'Euler Progressivo';

metodos_disc(3).id = 'backward';
metodos_disc(3).nome = 'Euler Regressivo';

% -------------------------------------------------------------------
% 1. LUGAR DAS RAÍZES - Cancelamento Polo-Zero
% -------------------------------------------------------------------
controladores(1).id = 'RL';
controladores(1).nome = 'Root Locus - Cancelamento';
controladores(1).Kp = 4 / K;
controladores(1).Ki = controladores(1).Kp / tau;

% -------------------------------------------------------------------
% 2. ZIEGLER-NICHOLS - Malha Aberta
% -------------------------------------------------------------------
controladores(2).id = 'ZNA';
controladores(2).nome = 'Z-N Aberta';

controladores(2).Kp = (0.9 * tau) / (K * L);

Ti_zna = 3.33 * L;

controladores(2).Ki = controladores(2).Kp / Ti_zna;

% -------------------------------------------------------------------
% 3. ZIEGLER-NICHOLS - Malha Fechada
% -------------------------------------------------------------------
% Estimado pelo modelo de primeira ordem com atraso:
%
% G(s) = K*exp(-Ls)/(tau*s + 1)
%
% Ku é obtido pela margem de ganho.
% Tu é obtido pela frequência de cruzamento de fase:
%
% Tu = 2*pi/Wcg

G_atraso = tf(K, [tau 1], 'InputDelay', L);

[Gm, Pm, Wcg, Wcp] = margin(G_atraso);

if isinf(Gm) || isnan(Gm) || isempty(Wcg) || isnan(Wcg) || Wcg == 0
    error('Não foi possível estimar Ku e Tu. Verifique os valores de K, tau e L.');
end

Ku = Gm;
Tu = 2*pi/Wcg;

Kp_znc = 0.45 * Ku;
Ti_znc = 0.833 * Tu;
Ki_znc = Kp_znc / Ti_znc;

controladores(3).id = 'ZNC';
controladores(3).nome = 'Z-N Fechada';

controladores(3).Kp = Kp_znc;
controladores(3).Ki = Ki_znc;

fprintf('=== Ziegler-Nichols Malha Fechada Estimado ===\n');
fprintf('Ku estimado = %.4f\n', Ku);
fprintf('Tu estimado = %.4f s\n', Tu);
fprintf('Kp ZN fechado = %.4f\n', Kp_znc);
fprintf('Ki ZN fechado = %.4f\n\n', Ki_znc);

% -------------------------------------------------------------------
% 4. CHR - Rastreamento com 0% de sobressinal
% -------------------------------------------------------------------
controladores(4).id = 'CHR';
controladores(4).nome = 'CHR';

controladores(4).Kp = (0.35 * tau) / (K * L);

Ti_chr = 1.16 * tau;

controladores(4).Ki = controladores(4).Kp / Ti_chr;

% -------------------------------------------------------------------
% 5. IMC - Controle por Modelo Interno
% -------------------------------------------------------------------
lambda = 1.0;

controladores(5).id = 'IMC';
controladores(5).nome = 'IMC';

controladores(5).Kp = tau / (K * lambda);
controladores(5).Ki = controladores(5).Kp / tau;

% -------------------------------------------------------------------
% 6. LUGAR DAS RAÍZES CLÁSSICO - Mp = 10%, ts = 4s
% -------------------------------------------------------------------

Mp_rl_clas = 0.10;   % 10% de sobressinal
ts_rl_clas = 4.0;    % tempo de acomodação, critério de 2%

zeta_rl_clas = -log(Mp_rl_clas) / ...
               sqrt(pi^2 + (log(Mp_rl_clas))^2);

wn_rl_clas = 4 / (zeta_rl_clas * ts_rl_clas);

Kp_rl_clas = (2 * tau * zeta_rl_clas * wn_rl_clas - 1) / K;
Ki_rl_clas = (tau * wn_rl_clas^2) / K;

C_RL_CLAS_s = pid(Kp_rl_clas, Ki_rl_clas);

controladores(6).id = 'RL_CLAS';
controladores(6).nome = 'Root Locus Clássico';

controladores(6).Kp = Kp_rl_clas;
controladores(6).Ki = Ki_rl_clas;

% -------------------------------------------------------------------
% Discretização padronizada de TODOS os controladores PI
% -------------------------------------------------------------------
% Todos os métodos PI agora possuem:
% - Tustin
% - Euler Progressivo
% - Euler Regressivo

for i = 1:length(controladores)

    for j = 1:length(metodos_disc)

        metodo_id = metodos_disc(j).id;

        [Cz, q0, q1] = discretizarPI(...
            controladores(i).Kp, ...
            controladores(i).Ki, ...
            Ts, ...
            metodo_id);

        controladores(i).(metodo_id).C = Cz;
        controladores(i).(metodo_id).q0 = q0;
        controladores(i).(metodo_id).q1 = q1;
        controladores(i).(metodo_id).FT = feedback(Cz * G_ma_z, 1);

    end

end

% -------------------------------------------------------------------
% Variáveis individuais mantidas para facilitar leitura e compatibilidade
% com a estrutura original do relatório
% -------------------------------------------------------------------

Kp_rl  = controladores(1).Kp;
Ki_rl  = controladores(1).Ki;

Kp_zna = controladores(2).Kp;
Ki_zna = controladores(2).Ki;

Kp_znc = controladores(3).Kp;
Ki_znc = controladores(3).Ki;

Kp_chr = controladores(4).Kp;
Ki_chr = controladores(4).Ki;

Kp_imc = controladores(5).Kp;
Ki_imc = controladores(5).Ki;

Kp_rl_clas = controladores(6).Kp;
Ki_rl_clas = controladores(6).Ki;

% -------------------------------------------------------------------
% Controladores discretos individuais
% -------------------------------------------------------------------

C_RL_Tustin  = controladores(1).tustin.C;
C_RL_EulerP  = controladores(1).forward.C;
C_RL_EulerR  = controladores(1).backward.C;

C_ZNA_Tustin = controladores(2).tustin.C;
C_ZNA_EulerP = controladores(2).forward.C;
C_ZNA_EulerR = controladores(2).backward.C;

C_ZNC_Tustin = controladores(3).tustin.C;
C_ZNC_EulerP = controladores(3).forward.C;
C_ZNC_EulerR = controladores(3).backward.C;

C_CHR_Tustin = controladores(4).tustin.C;
C_CHR_EulerP = controladores(4).forward.C;
C_CHR_EulerR = controladores(4).backward.C;

C_IMC_Tustin = controladores(5).tustin.C;
C_IMC_EulerP = controladores(5).forward.C;
C_IMC_EulerR = controladores(5).backward.C;

C_RL_CLAS_Tustin = controladores(6).tustin.C;
C_RL_CLAS_EulerP = controladores(6).forward.C;
C_RL_CLAS_EulerR = controladores(6).backward.C;

% -------------------------------------------------------------------
% Malhas fechadas individuais
% -------------------------------------------------------------------

FT_RL_Tustin  = controladores(1).tustin.FT;
FT_RL_EulerP  = controladores(1).forward.FT;
FT_RL_EulerR  = controladores(1).backward.FT;

FT_ZNA_Tustin = controladores(2).tustin.FT;
FT_ZNA_EulerP = controladores(2).forward.FT;
FT_ZNA_EulerR = controladores(2).backward.FT;

FT_ZNC_Tustin = controladores(3).tustin.FT;
FT_ZNC_EulerP = controladores(3).forward.FT;
FT_ZNC_EulerR = controladores(3).backward.FT;

FT_CHR_Tustin = controladores(4).tustin.FT;
FT_CHR_EulerP = controladores(4).forward.FT;
FT_CHR_EulerR = controladores(4).backward.FT;

FT_IMC_Tustin = controladores(5).tustin.FT;
FT_IMC_EulerP = controladores(5).forward.FT;
FT_IMC_EulerR = controladores(5).backward.FT;

FT_RL_CLAS_Tustin = controladores(6).tustin.FT;
FT_RL_CLAS_EulerP = controladores(6).forward.FT;
FT_RL_CLAS_EulerR = controladores(6).backward.FT;

% -------------------------------------------------------------------
% Compatibilidade com nomes usados anteriormente
% Comparação principal usando Tustin
% -------------------------------------------------------------------

FT_MF_RL  = FT_RL_Tustin;
FT_MF_ZNA = FT_ZNA_Tustin;
FT_MF_ZNC = FT_ZNC_Tustin;
FT_MF_CHR = FT_CHR_Tustin;
FT_MF_IMC = FT_IMC_Tustin;


% -------------------------------------------------------------------
% DEADBEAT - Sintonia Digital Direta
% -------------------------------------------------------------------
% Definido antes das seções de impressão e gráficos para evitar variáveis
% inexistentes quando os modelos matemáticos forem exibidos.
z = tf('z', Ts);
C_DB_z = minreal((1 / G_ma_z) * (1 / (z - 1)));
FT_MF_DB = feedback(C_DB_z * G_ma_z, 1);

% -------------------------------------------------------------------
% Configuração dos gráficos
% -------------------------------------------------------------------
% O Ziegler-Nichols em malha fechada permanece calculado para o memorial,
% mas fica oculto nos gráficos, conforme organização final do relatório.
OCULTAR_ZN_FECHADA_GRAFICOS = true;
OPCOES_ZN_FECHADA_EXP = [7 8 9];

%% 15. EQUAÇÕES E GRÁFICOS PARA CADA CONTROLADOR E DISCRETIZAÇÃO

% Este bloco imprime:
% 1) Controlador discreto C(z)
% 2) Malha aberta controlada L(z) = C(z)*G(z)
% 3) Malha fechada H(z) = Y(z)/R(z)
%
% E gera um gráfico para cada controlador comparando:
% - Tustin
% - Euler Progressivo
% - Euler Regressivo

disp('===================================================================');
disp('      EQUAÇÕES DOS CONTROLADORES, MALHA ABERTA E MALHA FECHADA     ');
disp('===================================================================');

% Se quiser salvar tudo em um arquivo .txt, deixe ativado:
salvar_equacoes_txt = true;

if salvar_equacoes_txt
    diary('equacoes_controladores_discretizados.txt');
end

disp('===================================================================');
disp('                  1) CONTROLADORES DISCRETIZADOS C(z)              ');
disp('===================================================================');

for i = 1:length(controladores)

    fprintf('\n============================================================\n');
    fprintf('CONTROLADOR: %s\n', controladores(i).nome);
    fprintf('Kp = %.8f\n', controladores(i).Kp);
    fprintf('Ki = %.8f\n', controladores(i).Ki);
    fprintf('============================================================\n');

    for j = 1:length(metodos_disc)

        metodo_id = metodos_disc(j).id;
        metodo_nome = metodos_disc(j).nome;

        Cz = controladores(i).(metodo_id).C;

        fprintf('\n--- %s ---\n', metodo_nome);
        fprintf('Controlador discreto C(z):\n');

        Cz

        fprintf('Forma normalizada:\n');
        imprimirEquacaoNormalizada(Cz, 'C', 'z');

    end

end


disp('===================================================================');
disp('          2) FUNÇÕES EM MALHA ABERTA CONTROLADA L(z) = C(z)G(z)    ');
disp('===================================================================');

for i = 1:length(controladores)

    fprintf('\n============================================================\n');
    fprintf('CONTROLADOR: %s\n', controladores(i).nome);
    fprintf('============================================================\n');

    for j = 1:length(metodos_disc)

        metodo_id = metodos_disc(j).id;
        metodo_nome = metodos_disc(j).nome;

        Cz = controladores(i).(metodo_id).C;

        Lz = minreal(Cz * G_ma_z);

        fprintf('\n--- %s ---\n', metodo_nome);
        fprintf('Malha aberta controlada L(z) = C(z)G(z):\n');

        Lz

        fprintf('Forma normalizada:\n');
        imprimirEquacaoNormalizada(Lz, 'L', 'z');

    end

end


disp('===================================================================');
disp('          3) FUNÇÕES EM MALHA FECHADA H(z) = Y(z)/R(z)             ');
disp('===================================================================');

for i = 1:length(controladores)

    fprintf('\n============================================================\n');
    fprintf('CONTROLADOR: %s\n', controladores(i).nome);
    fprintf('============================================================\n');

    for j = 1:length(metodos_disc)

        metodo_id = metodos_disc(j).id;
        metodo_nome = metodos_disc(j).nome;

        Hz = controladores(i).(metodo_id).FT;

        fprintf('\n--- %s ---\n', metodo_nome);
        fprintf('Malha fechada H(z) = Y(z)/R(z):\n');

        Hz

        fprintf('Forma normalizada:\n');
        imprimirEquacaoNormalizada(Hz, 'H', 'z');

    end

end


% -------------------------------------------------------------------
% Deadbeat separado, se existir
% -------------------------------------------------------------------

if exist('FT_MF_DB', 'var')

    disp('===================================================================');
    disp('                         DEADBEAT                                  ');
    disp('===================================================================');

    fprintf('\nControlador Deadbeat C(z):\n');

    if exist('C_DB_z', 'var')
        C_DB_z
        fprintf('Forma normalizada:\n');
        imprimirEquacaoNormalizada(C_DB_z, 'C_DB', 'z');
    else
        warning('C_DB_z não foi encontrado.');
    end

    fprintf('\nMalha fechada Deadbeat H(z):\n');
    FT_MF_DB

    fprintf('Forma normalizada:\n');
    imprimirEquacaoNormalizada(FT_MF_DB, 'H_DB', 'z');

else
    warning('FT_MF_DB ainda não foi criado. Deadbeat não será impresso.');
end

if salvar_equacoes_txt
    diary off;
    fprintf('\nArquivo gerado: equacoes_controladores_discretizados.txt\n');
end

%% 15.1 ANÁLISE DE ESTABILIDADE DOS CONTROLADORES

disp('===================================================================');
disp('              ANÁLISE DE ESTABILIDADE EM MALHA FECHADA             ');
disp('===================================================================');

for i = 1:length(controladores)

    fprintf('\n============================================================\n');
    fprintf('Controlador: %s\n', controladores(i).nome);
    fprintf('============================================================\n');

    for j = 1:length(metodos_disc)

        metodo_id = metodos_disc(j).id;
        metodo_nome = metodos_disc(j).nome;

        Hz = controladores(i).(metodo_id).FT;

        polos = pole(Hz);
        modulos = abs(polos);

        fprintf('\nMétodo: %s\n', metodo_nome);
        fprintf('Polos:\n');
        disp(polos);

        fprintf('Módulos dos polos:\n');
        disp(modulos);

        if all(modulos < 1)
            fprintf('Resultado: ESTÁVEL, pois todos os polos estão dentro do círculo unitário.\n');
        else
            fprintf('Resultado: INSTÁVEL, pois existe polo fora do círculo unitário.\n');
        end

    end

end

%% 15.2. TABELA DE DESEMPENHO DOS CONTROLADORES - TUSTIN

disp('===================================================================');
disp('              TABELA DE DESEMPENHO DOS CONTROLADORES              ');
disp('===================================================================');

controladores_tustin = {
    'Root Locus - Cancelamento', FT_RL_Tustin;
    'Z-N Aberta',                FT_ZNA_Tustin;
    'CHR',                       FT_CHR_Tustin;
    'IMC',                       FT_IMC_Tustin;
    'Root Locus Clássico',       FT_RL_CLAS_Tustin
};

fprintf('\n%-30s %-12s %-15s %-15s %-12s %-12s\n', ...
    'Controlador', ...
    'RiseTime', ...
    'SettlingTime', ...
    'Overshoot (%)', ...
    'Peak', ...
    'PeakTime');

fprintf('%s\n', repmat('-', 1, 105));

for i = 1:size(controladores_tustin,1)

    nome = controladores_tustin{i,1};
    FT = controladores_tustin{i,2};

    info = stepinfo(FT);

    fprintf('%-30s %-12.4f %-15.4f %-15.4f %-12.4f %-12.4f\n', ...
        nome, ...
        info.RiseTime, ...
        info.SettlingTime, ...
        info.Overshoot, ...
        info.Peak, ...
        info.PeakTime);

end

%% 16. GRÁFICOS COMPARANDO DISCRETIZAÇÕES PARA CADA CONTROLADOR

disp('===================================================================');
disp('       GERANDO GRÁFICOS POR CONTROLADOR: TUSTIN x EULER P x EULER R');
disp('===================================================================');

t_comp_disc = 0:Ts:15;

for i = 1:length(controladores)

    % Oculta Ziegler-Nichols em malha fechada apenas dos gráficos
    if OCULTAR_ZN_FECHADA_GRAFICOS && strcmp(controladores(i).id, 'ZNC')
        continue;
    end

    figure('Name', ['Comparação de Discretizações - ' controladores(i).nome], ...
           'Color', 'w', ...
           'Position', [100, 100, 900, 600]);

    hold on;

    legendas = {};

    for j = 1:length(metodos_disc)

        metodo_id = metodos_disc(j).id;
        metodo_nome = metodos_disc(j).nome;

        Hz = controladores(i).(metodo_id).FT;

        [y_resp, t_resp] = step(Hz, t_comp_disc);

        stairs(t_resp, y_resp, 'LineWidth', 2);

        legendas{end+1} = metodo_nome;

    end

    plot(t_comp_disc, ones(size(t_comp_disc)), 'k--', 'LineWidth', 1.2);

    legendas{end+1} = 'Setpoint';

    title(['Resposta ao Degrau em Malha Fechada - ' controladores(i).nome], ...
          'FontSize', 14, ...
          'FontWeight', 'bold');

    xlabel('Tempo (s)', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Amplitude Normalizada', 'FontSize', 12, 'FontWeight', 'bold');

    legend(legendas, ...
           'Location', 'southeast', ...
           'Interpreter', 'none');

    grid on;

end

disp('Gráficos comparativos de discretização gerados com sucesso.');
% -------------------------------------------------------------------
% DEADBEAT - Sintonia Digital Direta
% -------------------------------------------------------------------
% Mantido separado, conforme solicitado.
% OBS.: a expressão abaixo é a do script original e deve ser ajustada
% posteriormente, pois o projeto deadbeat depende da forma desejada de T(z).

z = tf('z', Ts);

C_DB_z = minreal((1 / G_ma_z) * (1 / (z - 1)));

FT_MF_DB = feedback(C_DB_z * G_ma_z, 1);

disp('Controladores PI calculados e discretizados por Tustin, Euler Progressivo e Euler Regressivo.');
disp('Root Locus clássico adicionado com Mp = 10% e ts = 4s.');
disp('Deadbeat mantido separado para ajuste posterior.');

%% FIGURA PARA O RELATÓRIO - DISCRETIZAÇÃO DOS MODELOS
% Comparação entre Tustin, Euler Progressivo e Euler Regressivo
% para as principais sintonias, removendo Ziegler-Nichols em malha fechada.

figure('Name', 'Discretizacao dos Modelos - Relatorio', ...
       'Color', 'w', ...
       'Position', [100, 100, 1100, 750]);

t_disc_relatorio = 0:Ts:20;

% Controladores escolhidos para o relatório:
% 1 -> Root Locus - Cancelamento
% 2 -> Z-N Aberta
% 4 -> CHR
% 5 -> IMC
idx_controladores_relatorio = [1 2 4 5];

titulos_relatorio = {
    'Root Locus - Cancelamento'
    'Z-N Malha Aberta'
    'CHR'
    'IMC'
};

for n = 1:length(idx_controladores_relatorio)

    i = idx_controladores_relatorio(n);

    subplot(2, 2, n);
    hold on;

    % Respostas das três discretizações
    [y_tustin,  t_tustin]  = step(controladores(i).tustin.FT,   t_disc_relatorio);
    [y_euler_p, t_euler_p] = step(controladores(i).forward.FT,  t_disc_relatorio);
    [y_euler_r, t_euler_r] = step(controladores(i).backward.FT, t_disc_relatorio);

    stairs(t_tustin,  y_tustin,  'g-',  'LineWidth', 1.8);
    stairs(t_euler_p, y_euler_p, 'r--', 'LineWidth', 1.6);
    stairs(t_euler_r, y_euler_r, 'b-.', 'LineWidth', 1.6);

    plot(t_disc_relatorio, ones(size(t_disc_relatorio)), ...
         'k:', 'LineWidth', 1.2);

    title(titulos_relatorio{n}, ...
          'FontSize', 12, ...
          'FontWeight', 'bold');

    xlabel('Tempo (s)');
    ylabel('Amplitude');

    xlim([0 20]);
    ylim([0 1.5]);

    grid on;

    % Coloca legenda apenas no primeiro gráfico para não poluir a figura
    if n == 1
        legend('Tustin', ...
               'Euler Prog.', ...
               'Euler Reg.', ...
               'Setpoint', ...
               'Location', 'southeast');
    end

end

sgtitle('Análise de Discretização (Tustin vs Eulers) para Diferentes Sintonias', ...
        'FontSize', 14, ...
        'FontWeight', 'bold');

% Salva automaticamente a figura para inserir no relatório
exportgraphics(gcf, 'discretizacao_modelos_relatorio.png', 'Resolution', 300);

%% 6. ANÁLISE GRÁFICA DA DISCRETIZAÇÃO - ROOT LOCUS POR CANCELAMENTO

figure('Name', 'Analise de Discretizacao - Root Locus', 'Color', 'w');

t_sim_disc = 0:Ts:50;

[y_tustin, ~]  = step(FT_RL_Tustin,  t_sim_disc);
[y_euler_p, ~] = step(FT_RL_EulerP,  t_sim_disc);
[y_euler_r, ~] = step(FT_RL_EulerR,  t_sim_disc);

stairs(t_sim_disc, y_tustin,  'g',  'LineWidth', 2); hold on;
stairs(t_sim_disc, y_euler_p, 'r--','LineWidth', 1.5);
stairs(t_sim_disc, y_euler_r, 'b-.','LineWidth', 1.5);

plot(t_sim_disc, ones(size(t_sim_disc)), 'k:', 'LineWidth', 1);

title('Comparação dos Métodos de Discretização - Root Locus por Cancelamento');
xlabel('Tempo (s)');
ylabel('Amplitude');

legend('Tustin', ...
       'Euler Progressivo', ...
       'Euler Regressivo', ...
       'Setpoint', ...
       'Location', 'southeast');

grid on;

disp('Análise gráfica de discretização do Root Locus por cancelamento gerada com sucesso.');

%% 6.1 COMPARAÇÃO ENTRE ROOT LOCUS POR CANCELAMENTO E ROOT LOCUS CLÁSSICO

t_comp = 0:Ts:20;

[y_cancel, t_cancel] = step(FT_MF_RL, t_comp);
[y_clas,   t_clas]   = step(FT_RL_CLAS_Tustin, t_comp);

figure('Name', 'Root Locus: Cancelamento vs Classico', 'Color', 'w');

stairs(t_cancel, y_cancel, 'b', 'LineWidth', 2); hold on;
stairs(t_clas,   y_clas,   'r', 'LineWidth', 2);

plot(t_comp, ones(size(t_comp)), 'k--', 'LineWidth', 1);

title('Lugar das Raízes: Cancelamento Polo-Zero vs Projeto Clássico');
xlabel('Tempo (s)');
ylabel('Amplitude Normalizada');

legend('Cancelamento Polo-Zero', ...
       'Root Locus Clássico: Mp = 10%, ts = 4s', ...
       'Setpoint', ...
       'Location', 'southeast');

grid on;

%% 7. COMPARAÇÃO DOS MÉTODOS DE SINTONIA USANDO TUSTIN
% Esta figura mantém a lógica original: comparar os métodos de sintonia.
% A diferença é que agora fica explícito que todos estão em Tustin.

t_simulacao = 0:Ts:15;

[y_rl,  t_rl]  = step(FT_MF_RL,  t_simulacao);
[y_zna, t_zna] = step(FT_MF_ZNA, t_simulacao);
% [y_znc, t_znc] = step(FT_MF_ZNC, t_simulacao);  % Oculto dos gráficos
[y_chr, t_chr] = step(FT_MF_CHR, t_simulacao);
[y_imc, t_imc] = step(FT_MF_IMC, t_simulacao);
[y_db,  t_db]  = step(FT_MF_DB,  t_simulacao);

figure('Name', 'Comparação dos Controladores - Tustin', 'Color', 'w', 'Position', [100, 100, 900, 600]);

stairs(t_rl,  y_rl,  'b-',  'LineWidth', 2); hold on;
stairs(t_zna, y_zna, 'r--', 'LineWidth', 2);
% stairs(t_znc, y_znc, 'm-.', 'LineWidth', 2);  % Z-N Fechada removido do gráfico
stairs(t_chr, y_chr, 'g-',  'LineWidth', 2);
stairs(t_imc, y_imc, 'k:',  'LineWidth', 2);
stairs(t_db,  y_db,  'c-',  'LineWidth', 2);
plot(t_simulacao, ones(size(t_simulacao)), 'Color', [0.7 0.7 0.7], 'LineWidth', 1, 'LineStyle', '--');

title('Resposta ao Degrau: Comparação dos Métodos de Sintonia (PIs em Tustin)', 'FontSize', 14, 'FontWeight', 'bold');
xlabel('Tempo (s)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel('Amplitude (Normalizada)', 'FontSize', 12, 'FontWeight', 'bold');
xlim([0 15]);
ylim([0 1.25]);
legend('Root Locus', 'Z-N Aberta', 'CHR', 'IMC', 'Deadbeat', 'Setpoint', 'Location', 'southeast', 'FontSize', 11);
grid on;

%% 8. COMPARAÇÃO AUTOMÁTICA: DISCRETIZAÇÕES PARA CADA SINTONIA
% Gera uma figura para cada sintonia PI comparando Tustin, Euler Progressivo
% e Euler Regressivo.

for i = 1:length(controladores)
    
    % Oculta Ziegler-Nichols em malha fechada apenas dos gráficos
    if OCULTAR_ZN_FECHADA_GRAFICOS && strcmp(controladores(i).id, 'ZNC')
        continue;
    end

    figure('Name', ['Discretizacoes - ', controladores(i).nome], 'Color', 'w', 'Position', [120, 120, 850, 520]);
    hold on;

    for j = 1:length(metodos_disc)
        metodo_id = metodos_disc(j).id;
        FT_temp = controladores(i).(metodo_id).FT;
        [y_temp, t_temp] = step(FT_temp, t_simulacao);
        stairs(t_temp, y_temp, 'LineWidth', 2);
    end

    plot(t_simulacao, ones(size(t_simulacao)), 'k--', 'LineWidth', 1);
    title(['Comparação das Discretizações - ', controladores(i).nome], 'FontSize', 13, 'FontWeight', 'bold');
    xlabel('Tempo (s)', 'FontSize', 11, 'FontWeight', 'bold');
    ylabel('Amplitude Normalizada', 'FontSize', 11, 'FontWeight', 'bold');
    legend('Tustin', 'Euler Progressivo', 'Euler Regressivo', 'Setpoint', 'Location', 'southeast');
    xlim([0 15]);
    ylim([0 1.25]);
    grid on;
end

%% 9. EXIBIÇÃO DOS MODELOS MATEMÁTICOS PARA O RELATÓRIO
disp('===================================================================');
disp('           MODELOS MATEMÁTICOS DOS CONTROLADORES C(z)              ');
disp('===================================================================');

disp('1. Controlador PI - Lugar das Raízes (Tustin):');
C_RL_Tustin

disp('2. Controlador PI - Ziegler-Nichols Malha Aberta (Tustin):');
C_ZNA_Tustin

disp('3. Controlador PI - Ziegler-Nichols Malha Fechada (Tustin):');
C_ZNC_Tustin

disp('4. Controlador PI - CHR (Tustin):');
C_CHR_Tustin

disp('5. Controlador PI - IMC (Tustin):');
C_IMC_Tustin

disp('6. Controlador Discreto - Deadbeat (z):');
C_DB_z

disp('===================================================================');
disp('       MODELOS MATEMÁTICOS EM MALHA FECHADA COMPLETA FT_MF(z)      ');
disp('===================================================================');

disp('1. Malha Fechada Completa - Lugar das Raízes (Tustin):');
FT_MF_RL

disp('2. Malha Fechada Completa - Ziegler-Nichols Malha Aberta (Tustin):');
FT_MF_ZNA

disp('3. Malha Fechada Completa - Ziegler-Nichols Malha Fechada (Tustin):');
FT_MF_ZNC

disp('4. Malha Fechada Completa - CHR (Tustin):');
FT_MF_CHR

disp('5. Malha Fechada Completa - IMC (Tustin):');
FT_MF_IMC

disp('6. Malha Fechada Completa - Deadbeat:');
FT_MF_DB

%% 10. RESUMO DOS GANHOS CALCULADOS (Kp e Ki)
disp('===================================================================');
disp('                  RESUMO DOS GANHOS (Kp e Ki)                      ');
disp('===================================================================');

for i = 1:length(controladores)
    fprintf('%d. %s:\n', i, controladores(i).nome);
    fprintf('   Kp = %.6f \n   Ki = %.6f \n\n', controladores(i).Kp, controladores(i).Ki);
end

disp('6. Deadbeat:');
disp('   [Metodo de sintonia digital direta. Nao possui Kp e Ki de PI]');
disp('===================================================================');

%% 11. COEFICIENTES q0 E q1 PARA IMPLEMENTAÇÃO NO ARDUINO
disp('===================================================================');
disp('       COEFICIENTES PARA O ARDUINO - FORMA INCREMENTAL DO PI        ');
disp('===================================================================');
disp('Equação usada no Arduino:');
disp('u(k) = u(k-1) + q0*e(k) + q1*e(k-1)');
disp(' ');

for i = 1:length(controladores)
    fprintf('\n--- %s ---\n', controladores(i).nome);
    fprintf('Kp = %.6f | Ki = %.6f\n', controladores(i).Kp, controladores(i).Ki);

    for j = 1:length(metodos_disc)
        metodo_id = metodos_disc(j).id;
        fprintf('  %s:\n', metodos_disc(j).nome);
        fprintf('     q0 = %.8f\n', controladores(i).(metodo_id).q0);
        fprintf('     q1 = %.8f\n', controladores(i).(metodo_id).q1);
    end
end

disp('===================================================================');

%% 12. SIMULAÇÃO DE REJEIÇÃO A CARGA PARA TODOS OS MÉTODOS (PIs EM TUSTIN)
disp('--- Simulando a Rejeição a Perturbações (Carga no Motor) ---');

% 1. Definindo o tempo de simulação e os sinais
t_carga = 0:Ts:30;
setpoint_sinal = ones(size(t_carga));
carga_sinal = zeros(size(t_carga));
idx_15s = find(t_carga >= 15, 1);
carga_sinal(idx_15s:end) = -0.30;     % Carga rouba 30% da energia aos 15s

% 2. Funções de Transferência da Carga: G / (1 + C*G)
% OBS.: Esta modelagem assume que a perturbação entra no ramo da planta.
% Se a carga entrar em outro ponto do diagrama, esta FT deve ser ajustada.
FT_Dist_RL  = feedback(G_ma_z, C_RL_Tustin);
FT_Dist_ZNA = feedback(G_ma_z, C_ZNA_Tustin);
% FT_Dist_ZNC = feedback(G_ma_z, C_ZNC_Tustin);  % Oculto dos gráficos
FT_Dist_CHR = feedback(G_ma_z, C_CHR_Tustin);
FT_Dist_IMC = feedback(G_ma_z, C_IMC_Tustin);
FT_Dist_DB  = feedback(G_ma_z, C_DB_z);

% 3. Simulando as respostas individuais (Setpoint + Distúrbio)
y_real_rl  = lsim(FT_MF_RL,  setpoint_sinal, t_carga) + lsim(FT_Dist_RL,  carga_sinal, t_carga);
y_real_zna = lsim(FT_MF_ZNA, setpoint_sinal, t_carga) + lsim(FT_Dist_ZNA, carga_sinal, t_carga);
% y_real_znc = lsim(FT_MF_ZNC, setpoint_sinal, t_carga) + lsim(FT_Dist_ZNC, carga_sinal, t_carga);  % Oculto dos gráficos
y_real_chr = lsim(FT_MF_CHR, setpoint_sinal, t_carga) + lsim(FT_Dist_CHR, carga_sinal, t_carga);
y_real_imc = lsim(FT_MF_IMC, setpoint_sinal, t_carga) + lsim(FT_Dist_IMC, carga_sinal, t_carga);
y_real_db  = lsim(FT_MF_DB,  setpoint_sinal, t_carga) + lsim(FT_Dist_DB,  carga_sinal, t_carga);

% 4. Plotagem da Simulação com Carga
figure('Name', 'Resposta à Carga - PIs em Tustin', 'Color', 'w', 'Position', [100, 100, 900, 600]);

stairs(t_carga, y_real_rl,  'b-',  'LineWidth', 2); hold on;
stairs(t_carga, y_real_zna, 'r--', 'LineWidth', 2);
% stairs(t_carga, y_real_znc, 'm-.', 'LineWidth', 2);  % Z-N Fechada removido do gráfico
stairs(t_carga, y_real_chr, 'g-',  'LineWidth', 2);
stairs(t_carga, y_real_imc, 'k:',  'LineWidth', 2);
stairs(t_carga, y_real_db,  'c-',  'LineWidth', 2);
plot(t_carga, setpoint_sinal, 'Color', [0.7 0.7 0.7], 'LineWidth', 1, 'LineStyle', '--');

title('Resposta do Motor à Aplicação de Carga Mecânica', 'FontSize', 14, 'FontWeight', 'bold');
xlabel('Tempo (s)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel('Amplitude', 'FontSize', 12, 'FontWeight', 'bold');
xline(15, 'r:', 'LineWidth', 1.5);
text(15.2, 0.4, '\leftarrow Carga Mecânica (-30%)', 'Color', 'r', 'FontSize', 11, 'FontWeight', 'bold');
xlim([0 30]);
ylim([0 1.25]);
legend('Root Locus', 'Z-N Aberta', 'CHR', 'IMC', 'Deadbeat', 'Setpoint', 'Location', 'southeast', 'FontSize', 11);
grid on;

%% 13. COMPARAÇÃO COM O LUGAR DAS RAÍZES CLÁSSICO (SEM CANCELAMENTO)
disp('--- Projetando o Lugar das Raízes Clássico (Segunda Ordem) ---');

% 1. Especificações de projeto desejadas para a forma clássica
Mp_desejado = 0.10; % 10% de sobressinal
ts_desejado = 4.0;  % 4 segundos de tempo de acomodação (critério de 2%)

% 2. Cálculo dos parâmetros de segunda ordem correspondentes
zeta_desejado = -log(Mp_desejado) / sqrt(pi^2 + (log(Mp_desejado))^2);
wn_desejado = 4 / (zeta_desejado * ts_desejado);

% 3. Determinação analítica dos ganhos Kp e Ki correspondentes
% Igualando a equação característica de malha fechada do sistema PI + Planta
% com o polinômio padrão de segunda ordem: s^2 + 2*zeta*wn*s + wn^2 = 0
Kp_clas = (2 * tau * zeta_desejado * wn_desejado - 1) / K;
Ki_clas = (tau * (wn_desejado^2)) / K;

% 4. Montando o controlador clássico e discretizando com a mesma função padrão
[C_clas_z, q0_clas, q1_clas] = discretizarPI(Kp_clas, Ki_clas, Ts, 'tustin');

% 5. Fechando a malha com a planta discreta
FT_MF_Clas = feedback(C_clas_z * G_ma_z, 1);

% 6. Simulação do degrau unitário para comparação
t_comp = 0:Ts:20;
y_cancelamento = step(FT_MF_RL, t_comp);
y_classico     = step(FT_MF_Clas, t_comp);

% 7. Plotagem Comparativa para o Relatório
figure('Name', 'Lugar das Raizes: Cancelamento vs Classico', 'Color', 'w', 'Position', [150, 150, 800, 500]);
stairs(t_comp, y_cancelamento, 'b', 'LineWidth', 2); hold on;
stairs(t_comp, y_classico, 'r', 'LineWidth', 2);
plot(t_comp, ones(size(t_comp)), 'k--', 'LineWidth', 1);

title('Abordagens no Lugar das Raízes: Cancelamento Polo-Zero vs. Projeto Clássico', 'FontSize', 12, 'FontWeight', 'bold');
xlabel('Tempo (s)', 'FontSize', 11);
ylabel('Amplitude', 'FontSize', 11);
legend('Cancelamento Polo-Zero (Atual - 1ª Ordem)', 'Lugar das Raízes Clássico (2ª Ordem)', 'Setpoint', 'Location', 'southeast', 'FontSize', 10);
grid on;

fprintf('Ganhos do Método Clássico Calculados:\n');
fprintf('   Kp_clas = %.4f\n   Ki_clas = %.4f\n', Kp_clas, Ki_clas);
fprintf('   q0_clas = %.8f\n   q1_clas = %.8f\n\n', q0_clas, q1_clas);

%% 14. BLOCO DE CÓDIGO PARA ARDUINO - Kp e Ki
% Esta seção imprime no console um bloco pronto para copiar no Arduino.
% O Arduino calcula q0 e q1 automaticamente a partir de Kp, Ki e do método
% de discretização escolhido.

disp('===================================================================');
disp('           BLOCO PRONTO PARA COPIAR NO CÓDIGO ARDUINO              ');
disp('===================================================================');
fprintf('\n');

fprintf('//=============================================================================\n');
fprintf('// ESCOLHA DA SINTONIA E DO MÉTODO DE DISCRETIZAÇÃO\n');
fprintf('//=============================================================================\n\n');

fprintf('// SINTONIA_PI:\n');

for i = 1:length(controladores)
    fprintf('// %2d -> %s\n', i, controladores(i).nome);
end

fprintf('//\n');
fprintf('// METODO_DISC:\n');

for j = 1:length(metodos_disc)
    fprintf('// %2d -> %s\n', j, metodos_disc(j).nome);
end

fprintf('\n');

fprintf('#define SINTONIA_PI 1\n');
fprintf('#define METODO_DISC 1\n');
fprintf('#define USAR_AJUSTE_MANUAL 0\n\n');

fprintf('//=============================================================================\n');
fprintf('// AJUSTE MANUAL\n');
fprintf('//=============================================================================\n');
fprintf('// Se quiser ajustar empiricamente na bancada, coloque:\n');
fprintf('// #define USAR_AJUSTE_MANUAL 1\n');
fprintf('// e altere Kp e Ki abaixo.\n');
fprintf('//=============================================================================\n\n');

fprintf('#if USAR_AJUSTE_MANUAL == 1\n\n');

fprintf('// Ajuste manual inicial\n');
fprintf('float Kp = %.8ff;\n', controladores(1).Kp);
fprintf('float Ki = %.8ff;\n\n', controladores(1).Ki);

fprintf('#else\n\n');

for i = 1:length(controladores)

    if i == 1
        fprintf('#if SINTONIA_PI == %d\n', i);
    else
        fprintf('#elif SINTONIA_PI == %d\n', i);
    end

    fprintf('// %s\n', controladores(i).nome);
    fprintf('float Kp = %.8ff;\n', controladores(i).Kp);
    fprintf('float Ki = %.8ff;\n\n', controladores(i).Ki);

end

fprintf('#else\n');
fprintf('#error "SINTONIA_PI invalida."\n');
fprintf('#endif\n\n');

fprintf('#endif\n\n');

disp('===================================================================');
%% 15. COMPARAÇÃO EXPERIMENTAL DA BANCADA - COM E SEM CARGA

% Este bloco lê os arquivos .txt gerados pelo Arduino e compara
% experimentalmente os controladores testados na bancada.
%
% Os arquivos podem estar em .zip ou em pastas já extraídas.

disp('===================================================================');
disp('        COMPARAÇÃO EXPERIMENTAL DA BANCADA - COM E SEM CARGA       ');
disp('===================================================================');

% -------------------------------------------------------------------
% Configurações
% -------------------------------------------------------------------

Ts_exp = 0.1;              % mesmo tempo de amostragem usado no Arduino
normalizar_por_SP = true;  % true -> plota ADC/SP
aplicar_filtro_plot = true;

% Caminho da pasta onde está este arquivo .m
pasta_script = fileparts(mfilename('fullpath'));

if isempty(pasta_script)
    pasta_script = pwd;
end

% O script pode ficar na raiz do projeto ou dentro da pasta "codigo".
% Esta lógica procura automaticamente a pasta "dados".
if isfolder(fullfile(pasta_script, 'dados'))
    pasta_projeto = pasta_script;
elseif isfolder(fullfile(fileparts(pasta_script), 'dados'))
    pasta_projeto = fileparts(pasta_script);
else
    pasta_projeto = pasta_script;
end

pasta_dados = fullfile(pasta_projeto, 'dados');

% ZIPs principais usados nos gráficos experimentais
zip_sem_carga = fullfile(pasta_dados, 'sem carga (1).zip');
zip_com_carga = fullfile(pasta_dados, 'com carga.zip');

% ZIPs extras específicos do Ziegler-Nichols
% dados_sem_carga.zip -> Ziegler-Nichols sem carga
% dados_com_carga.zip -> Ziegler-Nichols com carga
zip_zn_sem_carga = fullfile(pasta_dados, 'dados_sem_carga.zip');
zip_zn_com_carga = fullfile(pasta_dados, 'dados_com_carga.zip');

% Pastas de extração dos ZIPs principais
pasta_sem_carga = fullfile(pasta_projeto, 'dados_sem_carga_extraidos');
pasta_com_carga = fullfile(pasta_projeto, 'dados_com_carga_extraidos');

% Pastas de extração dos ZIPs extras do Ziegler-Nichols
pasta_zn_sem_carga = fullfile(pasta_projeto, 'zn_sem_carga_extraido');
pasta_zn_com_carga = fullfile(pasta_projeto, 'zn_com_carga_extraido');

% -------------------------------------------------------------------
% Lista de nomes dos controladores
% -------------------------------------------------------------------

nomes_opcoes = strings(18,1);

nomes_opcoes(1)  = "Root Locus - Cancelamento - Tustin";
nomes_opcoes(2)  = "Root Locus - Cancelamento - Euler Progressivo";
nomes_opcoes(3)  = "Root Locus - Cancelamento - Euler Regressivo";

nomes_opcoes(4)  = "Z-N Aberta - Tustin";
nomes_opcoes(5)  = "Z-N Aberta - Euler Progressivo";
nomes_opcoes(6)  = "Z-N Aberta - Euler Regressivo";

nomes_opcoes(7)  = "Z-N Fechada - Tustin";
nomes_opcoes(8)  = "Z-N Fechada - Euler Progressivo";
nomes_opcoes(9)  = "Z-N Fechada - Euler Regressivo";

nomes_opcoes(10) = "CHR - Tustin";
nomes_opcoes(11) = "CHR - Euler Progressivo";
nomes_opcoes(12) = "CHR - Euler Regressivo";

nomes_opcoes(13) = "IMC - Tustin";
nomes_opcoes(14) = "IMC - Euler Progressivo";
nomes_opcoes(15) = "IMC - Euler Regressivo";

nomes_opcoes(16) = "Root Locus Clássico - Tustin";
nomes_opcoes(17) = "Root Locus Clássico - Euler Progressivo";
nomes_opcoes(18) = "Root Locus Clássico - Euler Regressivo";

% -------------------------------------------------------------------
% Descompacta os arquivos, se existirem
% -------------------------------------------------------------------
% As pastas de extração são recriadas a cada execução para evitar
% leitura de arquivos antigos de execuções anteriores.

if isfile(zip_sem_carga)
    if isfolder(pasta_sem_carga)
        rmdir(pasta_sem_carga, 's');
    end
    mkdir(pasta_sem_carga);
    unzip(zip_sem_carga, pasta_sem_carga);
else
    warning('Arquivo "%s" não encontrado. Verifique o nome ou o caminho.', zip_sem_carga);
end

if isfile(zip_com_carga)
    if isfolder(pasta_com_carga)
        rmdir(pasta_com_carga, 's');
    end
    mkdir(pasta_com_carga);
    unzip(zip_com_carga, pasta_com_carga);
else
    warning('Arquivo "%s" não encontrado. Verifique o nome ou o caminho.', zip_com_carga);
end

% -------------------------------------------------------------------
% Descompacta os ZIPs extras do Ziegler-Nichols
% -------------------------------------------------------------------

if isfile(zip_zn_sem_carga)
    if isfolder(pasta_zn_sem_carga)
        rmdir(pasta_zn_sem_carga, 's');
    end
    mkdir(pasta_zn_sem_carga);
    unzip(zip_zn_sem_carga, pasta_zn_sem_carga);
else
    warning('Arquivo extra Ziegler-Nichols sem carga não encontrado: %s', zip_zn_sem_carga);
end

if isfile(zip_zn_com_carga)
    if isfolder(pasta_zn_com_carga)
        rmdir(pasta_zn_com_carga, 's');
    end
    mkdir(pasta_zn_com_carga);
    unzip(zip_zn_com_carga, pasta_zn_com_carga);
else
    warning('Arquivo extra Ziegler-Nichols com carga não encontrado: %s', zip_zn_com_carga);
end

% -------------------------------------------------------------------
% Carrega os dados experimentais
% -------------------------------------------------------------------

dados_sem_carga = carregarEnsaiosArduino(pasta_sem_carga, Ts_exp, nomes_opcoes);
dados_com_carga = carregarEnsaiosArduino(pasta_com_carga, Ts_exp, nomes_opcoes);

% -------------------------------------------------------------------
% PLOT 1 - ENSAIO SEM CARGA
% -------------------------------------------------------------------

figure('Name', 'Bancada Experimental - Sem Carga', ...
       'Color', 'w', ...
       'Position', [100, 100, 1000, 600]);

hold on;

legendas_sem = {};

for k = 1:length(dados_sem_carga)

    % Ignora Ziegler-Nichols em malha fechada nos gráficos experimentais
    if ismember(dados_sem_carga(k).opcao, OPCOES_ZN_FECHADA_EXP)
        continue;
    end

    t_plot = dados_sem_carga(k).t;
    y_plot = dados_sem_carga(k).ADC;

    if normalizar_por_SP
        y_plot = dados_sem_carga(k).ADC ./ dados_sem_carga(k).SP_medio;
    end

    if aplicar_filtro_plot
        y_plot = movmedian(y_plot, 3);
        y_plot = movmean(y_plot, 5);
    end

    [cor_linha, estilo_linha, largura_linha] = obterEstiloOpcao(dados_sem_carga(k).opcao);
    plot(t_plot, y_plot, ...
         'Color', cor_linha, ...
         'LineStyle', estilo_linha, ...
         'LineWidth', largura_linha);

    legendas_sem{end+1} = sprintf('%d - %s', ...
        dados_sem_carga(k).opcao, ...
        dados_sem_carga(k).nome);

end

% -------------------------------------------------------------------
% Adiciona ZIP extra: Ziegler-Nichols sem carga
% -------------------------------------------------------------------
% Este trecho lê o arquivo dados_sem_carga.zip, que contém o ensaio
% extra do Ziegler-Nichols sem carga.

arquivos_zn_sem = dir(fullfile(pasta_zn_sem_carga, '**', '*.txt'));

if ~isempty(arquivos_zn_sem)

    % Usa o maior arquivo .txt encontrado no ZIP, evitando arquivos auxiliares.
    [~, idx_zn_sem] = max([arquivos_zn_sem.bytes]);
    caminho_zn_sem = fullfile(arquivos_zn_sem(idx_zn_sem).folder, arquivos_zn_sem(idx_zn_sem).name);

    ensaio_extra_sem = lerArquivoArduino(caminho_zn_sem, Ts_exp);

    if ~isempty(ensaio_extra_sem.ADC)

        t_plot = ensaio_extra_sem.t;
        y_plot = ensaio_extra_sem.ADC;

        if normalizar_por_SP
            y_plot = ensaio_extra_sem.ADC ./ mean(ensaio_extra_sem.SP);
        end

        if aplicar_filtro_plot
            y_plot = movmedian(y_plot, 3);
            y_plot = movmean(y_plot, 5);
        end

        plot(t_plot, y_plot, ...
             'Color', [0.3500 0.1500 0.0500], ...
             'LineStyle', '-', ...
             'LineWidth', 3.0);

        legendas_sem{end+1} = 'Ziegler-Nichols - Sem Carga';

        fprintf('Ziegler-Nichols sem carga lido de: %s\n', caminho_zn_sem);

    end

else
    warning('Nenhum arquivo .txt encontrado no ZIP extra Ziegler-Nichols sem carga.');
end

if normalizar_por_SP
    yline(1, 'k--', 'Setpoint', 'LineWidth', 1.2);
    ylabel('Amplitude Normalizada ADC/SP');
else
    yline(400, 'k--', 'Setpoint', 'LineWidth', 1.2);
    ylabel('ADC');
end

title('Resposta Experimental ao Degrau - Sem Carga', ...
      'FontSize', 14, ...
      'FontWeight', 'bold');

xlabel('Tempo (s)');
grid on;

legend(legendas_sem, ...
       'Location', 'southeast', ...
       'Interpreter', 'none');


% -------------------------------------------------------------------
% PLOT 2 - ENSAIO COM CARGA
% -------------------------------------------------------------------

figure('Name', 'Bancada Experimental - Com Carga', ...
       'Color', 'w', ...
       'Position', [150, 150, 1000, 600]);

hold on;

legendas_carga = {};

for k = 1:length(dados_com_carga)

    % Ignora Ziegler-Nichols em malha fechada e Root Locus Clássico no ensaio com carga
    % 7, 8 e 9  -> Z-N Fechada
    % 16, 17 e 18 -> Root Locus Clássico
    if ismember(dados_com_carga(k).opcao, [OPCOES_ZN_FECHADA_EXP 16 17 18])
        continue;
    end

    t_plot = dados_com_carga(k).t;
    y_plot = dados_com_carga(k).ADC;

    if normalizar_por_SP
        y_plot = dados_com_carga(k).ADC ./ dados_com_carga(k).SP_medio;
    end

    if aplicar_filtro_plot
        y_plot = movmedian(y_plot, 3);
        y_plot = movmean(y_plot, 5);
    end

    [cor_linha, estilo_linha, largura_linha] = obterEstiloOpcao(dados_com_carga(k).opcao);
    plot(t_plot, y_plot, ...
         'Color', cor_linha, ...
         'LineStyle', estilo_linha, ...
         'LineWidth', largura_linha);

    legendas_carga{end+1} = sprintf('%d - %s', ...
        dados_com_carga(k).opcao, ...
        dados_com_carga(k).nome);

end

% -------------------------------------------------------------------
% Adiciona ZIP extra: Ziegler-Nichols com carga
% -------------------------------------------------------------------
% Este trecho lê o arquivo dados_com_carga.zip, que contém o ensaio
% extra do Ziegler-Nichols com carga.

arquivos_zn_com = dir(fullfile(pasta_zn_com_carga, '**', '*.txt'));

if ~isempty(arquivos_zn_com)

    % Usa o maior arquivo .txt encontrado no ZIP, evitando arquivos auxiliares.
    [~, idx_zn_com] = max([arquivos_zn_com.bytes]);
    caminho_zn_com = fullfile(arquivos_zn_com(idx_zn_com).folder, arquivos_zn_com(idx_zn_com).name);

    ensaio_extra_carga = lerArquivoArduino(caminho_zn_com, Ts_exp);

    if ~isempty(ensaio_extra_carga.ADC)

        t_plot = ensaio_extra_carga.t;
        y_plot = ensaio_extra_carga.ADC;

        if normalizar_por_SP
            y_plot = ensaio_extra_carga.ADC ./ mean(ensaio_extra_carga.SP);
        end

        if aplicar_filtro_plot
            y_plot = movmedian(y_plot, 3);
            y_plot = movmean(y_plot, 5);
        end

        plot(t_plot, y_plot, ...
             'Color', [0.3500 0.1500 0.0500], ...
             'LineStyle', '-', ...
             'LineWidth', 3.0);

        legendas_carga{end+1} = 'Ziegler-Nichols - Com Carga';

        fprintf('Ziegler-Nichols com carga lido de: %s\n', caminho_zn_com);

    end

else
    warning('Nenhum arquivo .txt encontrado no ZIP extra Ziegler-Nichols com carga.');
end

if normalizar_por_SP
    yline(1, 'k--', 'Setpoint', 'LineWidth', 1.2);
    ylabel('Amplitude Normalizada ADC/SP');
else
    yline(400, 'k--', 'Setpoint', 'LineWidth', 1.2);
    ylabel('ADC');
end

title('Resposta Experimental do Motor à Aplicação de Carga Mecânica', ...
      'FontSize', 14, ...
      'FontWeight', 'bold');

xlabel('Tempo (s)');
grid on;

legend(legendas_carga, ...
       'Location', 'southeast', ...
       'Interpreter', 'none');

disp('Gráficos experimentais com e sem carga gerados com sucesso.');
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% FUNÇÕES LOCAIS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [Cz, q0, q1] = discretizarPI(Kp, Ki, Ts, metodo)
%DISCRETIZARPI Discretiza um controlador PI contínuo na forma incremental.
%
% Controlador contínuo:
%   C(s) = Kp + Ki/s
%
% Forma incremental para implementação no Arduino:
%   u(k) = u(k-1) + q0*e(k) + q1*e(k-1)

    switch lower(metodo)
        case 'tustin'
            q0 = Kp + Ki*Ts/2;
            q1 = -Kp + Ki*Ts/2;
            num = [2*Kp + Ki*Ts, Ki*Ts - 2*Kp];
            den = [2, -2];

        case {'forward', 'eulerp', 'euler_progressivo'}
            q0 = Kp;
            q1 = Ki*Ts - Kp;
            num = [Kp, Ki*Ts - Kp];
            den = [1, -1];

        case {'backward', 'eulerr', 'euler_regressivo'}
            q0 = Kp + Ki*Ts;
            q1 = -Kp;
            num = [Kp + Ki*Ts, -Kp];
            den = [1, -1];

        otherwise
            error('Método de discretização inválido. Use: tustin, forward ou backward.');
    end

    Cz = tf(num, den, Ts);
end
function dados = carregarEnsaiosArduino(pasta, Ts, nomes_opcoes)

    arquivos = dir(fullfile(pasta, '**', '*.txt'));

    dados = struct([]);

    contador = 1;

    for i = 1:length(arquivos)

        caminho = fullfile(arquivos(i).folder, arquivos(i).name);
        % Ignora arquivo inválido/específico
        if strcmpi(arquivos(i).name, '2_carga_7.txt')
            fprintf('Ignorando arquivo: %s\n', arquivos(i).name);
            continue;
        end

        opcao = identificarOpcaoArquivo(arquivos(i).name);

        if isnan(opcao) || opcao < 1 || opcao > length(nomes_opcoes)
            warning('Não foi possível identificar a opção do arquivo: %s', arquivos(i).name);
            continue;
        end

        ensaio = lerArquivoArduino(caminho, Ts);

        if isempty(ensaio.ADC)
            warning('Arquivo sem dados válidos: %s', arquivos(i).name);
            continue;
        end

        dados(contador).arquivo = arquivos(i).name;
        dados(contador).opcao = opcao;
        dados(contador).nome = char(nomes_opcoes(opcao));
        dados(contador).t = ensaio.t;
        dados(contador).SP = ensaio.SP;
        dados(contador).ADC = ensaio.ADC;
        dados(contador).PWM = ensaio.PWM;
        dados(contador).Erro = ensaio.Erro;
        dados(contador).SP_medio = mean(ensaio.SP);

        contador = contador + 1;

    end

    if isempty(dados)
        warning('Nenhum dado foi carregado da pasta: %s', pasta);
        return;
    end

    % Ordena os ensaios pela opção do controlador
    [~, idx] = sort([dados.opcao]);
    dados = dados(idx);

end


function opcao = identificarOpcaoArquivo(nome_arquivo)

    opcao = NaN;

    nome = char(nome_arquivo);

    % Caso sem carga: mtd10.txt, mtd11.txt, etc.
    token = regexp(nome, 'mtd(\d+)', 'tokens', 'once');

    if ~isempty(token)
        opcao = str2double(token{1});
        return;
    end

    % Caso com carga: 10_carga.txt, 16_carga.txt, etc.
    token = regexp(nome, '^(\d+)_carga', 'tokens', 'once');

    if ~isempty(token)
        opcao = str2double(token{1});
    end

    % Caso especial:
    % Exemplo: 2_carga_7.txt
    % Aqui considera que o último número representa a opção do controlador.
    token_especial = regexp(nome, '_carga_(\d+)', 'tokens', 'once');

    if ~isempty(token_especial)
        opcao = str2double(token_especial{1});
    end

end


function ensaio = lerArquivoArduino(caminho, Ts)

    texto = fileread(caminho);
    linhas = splitlines(string(texto));

    SP = [];
    ADC = [];
    PWM = [];
    Erro = [];

    for i = 1:length(linhas)

        linha = strtrim(linhas(i));

        if strlength(linha) == 0
            continue;
        end

        % Remove prefixo do Serial Monitor, caso exista:
        % Exemplo:
        % 16:56:25.372 -> SP:400.00,ADC:406.88,...
        if contains(linha, '->')
            partes = split(linha, '->');
            linha = strtrim(partes(end));
        end

        expr = ['SP:(?<SP>-?\d+\.?\d*)' ...
                ',ADC:(?<ADC>-?\d+\.?\d*)' ...
                ',PWM:(?<PWM>-?\d+\.?\d*)' ...
                ',Erro:(?<Erro>-?\d+\.?\d*)'];

        valor = regexp(linha, expr, 'names');

        if isempty(valor)
            continue;
        end

        SP(end+1,1) = str2double(valor.SP);
        ADC(end+1,1) = str2double(valor.ADC);
        PWM(end+1,1) = str2double(valor.PWM);
        Erro(end+1,1) = str2double(valor.Erro);

    end

    n = length(ADC);

    ensaio.t = (0:n-1)' * Ts;
    ensaio.SP = SP;
    ensaio.ADC = ADC;
    ensaio.PWM = PWM;
    ensaio.Erro = Erro;

end

function imprimirFTnormalizada(G, var)
%IMPRIMIRFTNORMALIZADA Imprime uma função de transferência discreta
% em forma normalizada, com o primeiro coeficiente do denominador igual a 1.

    [num, den] = tfdata(G, 'v');

    % Remove zeros iniciais pequenos, se existirem
    tol = 1e-10;

    while length(num) > 1 && abs(num(1)) < tol
        num(1) = [];
    end

    while length(den) > 1 && abs(den(1)) < tol
        den(1) = [];
    end

    % Normaliza pelo primeiro coeficiente do denominador
    fator = den(1);
    num = num / fator;
    den = den / fator;

    num_str = poly2str(num, var);
    den_str = poly2str(den, var);

    fprintf('H(%s) = (%s) / (%s)\n', var, num_str, den_str);

end

function ensaio = lerArquivoArduinoIgnorandoKpKi(caminho, Ts)
% Lê arquivos do Arduino no formato:
% SP:400.00,ADC:406.00,PWM:170.00,Erro:-6.00,Kp:2.07,Ki:0.24
%
% A função usa apenas SP, ADC, PWM e Erro.
% Kp e Ki são ignorados.

    texto = fileread(caminho);
    linhas = splitlines(string(texto));

    SP = [];
    ADC = [];
    PWM = [];
    Erro = [];

    for i = 1:length(linhas)

        linha = strtrim(linhas(i));

        if strlength(linha) == 0
            continue;
        end

        % Remove prefixo do Serial Monitor, caso exista:
        % Exemplo:
        % 16:56:25.372 -> SP:400.00,ADC:406.00,...
        if contains(linha, '->')
            partes = split(linha, '->');
            linha = strtrim(partes(end));
        end

        % Pega somente SP, ADC, PWM e Erro.
        % Ignora qualquer coisa depois de Erro, como Kp e Ki.
        expr = ['SP:(?<SP>-?\d+\.?\d*)' ...
                ',ADC:(?<ADC>-?\d+\.?\d*)' ...
                ',PWM:(?<PWM>-?\d+\.?\d*)' ...
                ',Erro:(?<Erro>-?\d+\.?\d*)'];

        valor = regexp(linha, expr, 'names');

        if isempty(valor)
            continue;
        end

        SP(end+1,1) = str2double(valor.SP);
        ADC(end+1,1) = str2double(valor.ADC);
        PWM(end+1,1) = str2double(valor.PWM);
        Erro(end+1,1) = str2double(valor.Erro);

    end

    n = length(ADC);

    ensaio.t = (0:n-1)' * Ts;
    ensaio.SP = SP;
    ensaio.ADC = ADC;
    ensaio.PWM = PWM;
    ensaio.Erro = Erro;

end


function [cor, estilo, largura] = obterEstiloOpcao(opcao)
%OBTERESTILOOPCAO Define cores e estilos fixos para os gráficos experimentais.
% Mantém todas as curvas em linha contínua para melhorar a visualização.

    estilo = '-';
    largura = 2.0;

    switch opcao

        % Root Locus - Cancelamento
        case 1
            cor = [0.0000 0.4470 0.7410];   % azul
        case 2
            cor = [0.8500 0.3250 0.0980];   % laranja
        case 3
            cor = [0.9290 0.6940 0.1250];   % amarelo/ocre

        % CHR
        case 10
            cor = [0.4940 0.1840 0.5560];   % roxo
        case 11
            cor = [0.4660 0.6740 0.1880];   % verde
        case 12
            cor = [0.3010 0.7450 0.9330];   % ciano

        % IMC
        case 13
            cor = [0.6350 0.0780 0.1840];   % vinho
        case 14
            cor = [0.0000 0.0000 0.0000];   % preto
            largura = 2.4;
        case 15
            cor = [0.6000 0.3000 0.0000];   % marrom
            largura = 2.4;

        % Root Locus Clássico
        case 16
            cor = [0.2500 0.2500 0.2500];   % cinza escuro
        case 17
            cor = [0.7000 0.4000 0.1000];   % marrom claro
        case 18
            cor = [0.1000 0.5000 0.3000];   % verde escuro

        otherwise
            cor = [0.2000 0.2000 0.2000];
    end

end

function imprimirEquacaoNormalizada(G, nome, var)
%IMPRIMIREQUACAONORMALIZADA
% Imprime uma função de transferência em forma polinomial normalizada.
%
% Exemplo:
% H(z) = (0.1529 z - 0.1454) / (z^2 - 1.8355 z + 0.8430)

    [num, den] = tfdata(G, 'v');

    tol = 1e-10;

    % Remove zeros iniciais muito pequenos do numerador
    while length(num) > 1 && abs(num(1)) < tol
        num(1) = [];
    end

    % Remove zeros iniciais muito pequenos do denominador
    while length(den) > 1 && abs(den(1)) < tol
        den(1) = [];
    end

    % Normaliza pelo primeiro coeficiente do denominador
    fator = den(1);

    num = num / fator;
    den = den / fator;

    num_str = poly2str(num, var);
    den_str = poly2str(den, var);

    fprintf('%s(%s) = (%s) / (%s)\n\n', nome, var, num_str, den_str);

end