classdef fm_sequence < matlab.mixin.Copyable
%FM_SEQUENCE Generate a random sequence of trials
% Provided an 'fm_task' object and other properties, generate a randomized
% sequence of trials of different conditions with a desired inter-trial
% interval model
%
% Input properties
%   <task> A filled 'fm_task' object
%   <numRuns> to generate
%   <runDuration> in seconds. All runs will be the same duration
%   <itiModel> is either 'fixed', 'uniform' or 'exponential' (a truncated
%     exponential distribution)
%   <itiParams> If itiModel is 'fixed', this is a single value indicating
%     the duration. Otherwise, it is a 2-element vector indicating the
%     minimum and maximum ITI lengths.
%   <TR> The temporal resolution of the sequence.
%
%   <matchProbabilitiesExactly> One of three values:
%     'eachRun': In each run, conditions will occur exactly in the
%       proportions specified in the fm_task object.
%     'acrossRuns': Across all runs, conditions will occur exactly in the
%       proportions specified in the fm_task object.
%     'no': After making a sequence where each condition occurs exactly in
%       the proportions specified in the fm_task object, the remaining time
%       is filled with more trials to minimize waste.
%   <lambda> The "steepness" of exponentially distributed ITIs. Smaller
%     values mean more shorter-duration ITIs. Default is 3.0.
%   <giveWarnings> Warn when more than 15% of run durations is unused. True
%     by default.
%
% Output properties
%   <eventList> A vector of fm_eventList objects (see fm_eventList). The
%     ID values are from 'EventIDs' from 'contentNumerical' column of the
%     'fm_task' object
%   <eventListWIti> Same as 'eventList', but also contains the ITIs (with
%     their ID set to 0)
%   <condIDsPerRun> Same sequence as above, but represented using the
%     condition IDs from the fm_task object rather than the events across
%     all conditions. The values correspond to the row of the fm_task
%     table.
%   <occupiedPercentage> The percentage of the total run that contains
%     trials
%
% Constructors
%   > obj = fm_sequence();
%   > obj = fm_sequence(task), where 'task' is an fm_task object.
%
% Methods
%   > obj.go() Generate sequence
%
% Beware
%   If you do a histogram of the ITIs, set a small bin width. Automatic
%   MATLAB behavior will seem to show a disproportional amount of the max
%   ITI.
%
% Example
%   seq = fm_sequence(task);
%   seq.itiModel = 'exponential';
%   seq.itiParams = [2 7];
%   seq.runDuration = 388;
%   seq.go();
%   seq.eventList(1) % the first run of the generated sequence
%
% Part of package funkyMage. November 2023.
% https://github.com/aj-abdujabborov/funkyMage

% Internal definitions:
% Condition (cond): trial type without its ITI
% Trial: a trial including the ITI
% TODO: make it possible to generate multiple runs, EACH having equal
%proportions of desired conditions

    properties (Dependent = true, SetAccess = private)
        task {mustBeA(task, 'fm_task')};
    end

    properties
        numRuns (1,1) {mustBePositive} = 1;
        runDuration {mustBePositive};
        itiModel string {matlab.system.mustBeMember(itiModel, {'fixed', 'uniform', 'exponential'})} = 'fixed';
        itiParams (1,:) {mustBeNonnegative} = 7;
        TR {mustBePositive} = 1;

        matchProbabilitiesExactly string {matlab.system.mustBeMember(matchProbabilitiesExactly, {'eachRun', 'acrossRuns', 'no'})} = 'eachRun';
        lambda (1,1) {mustBePositive} = 3.0;

        giveWarnings (1,1) logical = true;
    end

    properties (SetAccess = protected)
        eventList (1,:) fm_eventList;
        eventListWIti (1,:) fm_eventList;
        condIDsPerRun;
        occupiedPercentage;
    end

    properties (Access = protected)
        privateTask;

        probabilities (1,:) {mustBeNonnegative};
        durations (1,:) {iscell, mustBeVector(durations, 'allow-all-empties')};
        onsets (1,:) {iscell, mustBeVector(onsets, 'allow-all-empties')};
        eventIDs (1,:) {iscell, mustBeVector(eventIDs, 'allow-all-empties')};
        durationPerCond;
        
        epochsPerCond;
        meanCondDuration;
        multiRunDur;

        iti;
    end

    methods
        function obj = fm_sequence(task)
            if nargin == 1
                obj.task = task;
            end
        end

        function go(obj)
            obj.checkProperties();
            obj.computeItiParameters();
            obj.computeTrialParameters();

            if strcmpi(obj.matchProbabilitiesExactly, "eachrun")
                runInst = copy(obj);
                runInst.numRuns = 1;
                runInst.matchProbabilitiesExactly = "acrossRuns";
                for i = obj.numRuns:-1:1
                    runInst.go();
                    obj.eventList(i) = runInst.eventList(1);
                    obj.eventListWIti(i) = runInst.eventListWIti(1);
                    obj.condIDsPerRun{i} = runInst.condIDsPerRun{1};
                    obj.occupiedPercentage(i) = runInst.occupiedPercentage;
                end

            else
                obj.condIDsPerRun = obj.generateSequence();
                itiSeq = cell(1, obj.numRuns);
                for i = obj.numRuns:-1:1
                    itiSeq{i} = obj.generateItis(length(obj.condIDsPerRun{i}));
                    [obj.eventList(i), obj.eventListWIti(i)] = obj.assembleEventList(obj.condIDsPerRun{i}, itiSeq{i});
                end
            end            
        end
    end

    methods (Access = protected)
        function condIDsPerRun = generateSequence(obj)
            obj.multiRunDur = obj.runDuration * obj.numRuns;

            numTrialsTotalEst = floor(obj.multiRunDur / obj.meanCondDuration);
            numTrialsPerBatch = sum(obj.probabilities);
            numBatchesEst = ceil(numTrialsTotalEst / numTrialsPerBatch) + 1;
                % one batch = all conditions at their specified probabilities

            multiRunSeq = generateMultiRunSequence();
            [seqBreakpointsIdx, numBatches] = computeBreakpointsInMultiRunSequence(multiRunSeq);
            warnIfTimingsAreNotIdeal(numBatches);
            condIDsPerRun = breakMultiRunSequenceIntoRuns(multiRunSeq, seqBreakpointsIdx);

            function multiRunSeq = generateMultiRunSequence()
                multiRunSeq = table('Size', [numBatchesEst*numTrialsPerBatch 3],...
                                    'VariableNames', ["CondID", "CondDur", "CumDur"], ...
                                    'VariableTypes', ["double", "double", "double"]);
                
                for b = 1:numBatchesEst
                    seqOfCurrBatch = obj.get1ToNInTheseAmounts(obj.probabilities);
                    seqOfCurrBatch = seqOfCurrBatch(randperm(length(seqOfCurrBatch)));
                    
                    multiRunSeq.CondID((b-1)*numTrialsPerBatch+1 : b*numTrialsPerBatch) = seqOfCurrBatch;
                end
    
                multiRunSeq.TrialDur(:,1) = obj.durationPerCond(multiRunSeq.CondID) + obj.iti.mean;
                multiRunSeq.CumDur(:,1)  = cumsum(multiRunSeq.TrialDur);
            end

            function [breakpointsIdx, numBatches] = computeBreakpointsInMultiRunSequence(multiRunSeq)
                breakpointsIdx = nan(1, obj.numRuns);
                for n = 1:obj.numRuns
                    if n == 1
                        tmp = multiRunSeq.CumDur <= obj.runDuration;
                    else
                        tmp = multiRunSeq.CumDur <= obj.runDuration + multiRunSeq.CumDur(breakpointsIdx(n-1));
                    end
                    breakpointsIdx(n) = find(tmp, 1, 'last');
                end

                numBatches = floor(breakpointsIdx(end)/numTrialsPerBatch);
            
                if ~strcmpi(obj.matchProbabilitiesExactly, "no")
                    breakpointsIdx(end) = numBatches * numTrialsPerBatch;
                        % so that we don't have a fractional amount of batches
                end
            end

            function warnIfTimingsAreNotIdeal(numBatches)
                if numBatches == 0
                    error("A sequence with the specified parameters does not fit into the " + ...
                          "specified run duration or number of runs");
                end
    
                occupiedTime = numBatches * numTrialsPerBatch * obj.meanCondDuration;
                possibleTime = obj.numRuns * obj.runDuration;
                obj.occupiedPercentage = occupiedTime / possibleTime * 100;
    
                if obj.giveWarnings && obj.occupiedPercentage < 85
                    warning("Only %2.0f%% of the available time contains trials. You may want" + ...
                            "to adjust the parameters", obj.occupiedPercentage);
                end
            end

            function condIDsPerRun = breakMultiRunSequenceIntoRuns(multiRunSeq, seqBreakpointsIdx)
                condIDsPerRun = cell(1, obj.numRuns);
                tmp = [0 seqBreakpointsIdx];
                for n = 1:obj.numRuns
                    idx = tmp(n)+1 : tmp(n+1);
                    subSeqCurr = multiRunSeq.CondID(idx);
                    condIDsPerRun{n} = subSeqCurr(randperm(length(subSeqCurr)));
                        % shuffle sequence within run. useful to eliminate
                        % predictability when more than one batch can fit into a run
                end
            end
        end

        function itiSeq = generateItis(obj, nTrials)
            if strcmpi(obj.itiModel, 'fixed')
                itiSeq = generateFixedItis();
            elseif strcmpi(obj.itiModel, 'uniform')
                itiSeq = generateUniformItis();
            else
                itiSeq = generateTruncatedExponentialItis();
            end

            function itiSeq = generateFixedItis()
                itiSeq = obj.iti.mean * ones(1, nTrials);
            end

            function itiSeq = generateUniformItis()
                maxAttempts = 5;
                for j = 1:maxAttempts
                    itiSeq = rand(1, nTrials) * obj.iti.rangeAdj + obj.iti.minAdj;
                    itiSeq = round(itiSeq / obj.TR) * obj.TR;

                    [itiSeq, nominalMeanMatched] = adjustSeqToMatchNominalMean(itiSeq);

                    if nominalMeanMatched
                        return;
                    end
                end
                error("Uniform ITIs could not be generated. Try adjusting parameters.");
            end

            function itiSeq = generateTruncatedExponentialItis()
                maxAttempts = 5;
                for j = 1:maxAttempts
                    randVals = rand(1, nTrials);
                    R = randVals*(1-exp(-obj.iti.rangeAdj/obj.lambda));
                    itiSeqRes = -log(1-R) * obj.lambda + obj.iti.minAdj; % btw, lambda is not optimized
                    itiSeq = round(itiSeqRes/obj.TR)*obj.TR;

                    [itiSeq, nominalMeanMatched] = adjustSeqToMatchNominalMean(itiSeq);
                    if nominalMeanMatched
                        return;
                    end
                end
                error("Truncated exponential ITIs could not be generated. Try adjusting parameters.");
            end

            function [itiSeq, nominalMeanMatched] = adjustSeqToMatchNominalMean(itiSeq)
                % Function inspired by Neurodesign's _fix_iti method in 'generate.py'
                nominalMeanMatched = false;
                numChangesMade = 0;

                itiGapInSeq = sum(itiSeq) - obj.iti.mean*nTrials;
                while (abs(itiGapInSeq) > obj.TR) || (mean(itiSeq) > obj.iti.mean)
                    if itiGapInSeq > 0
                        changeablesIdx = find(itiSeq ~= obj.iti.min); % to avoid going past range
                    else
                        changeablesIdx = find(itiSeq ~= obj.iti.max);
                    end
                    randInd = changeablesIdx(randi(length(changeablesIdx)));
                    itiSeq(randInd) = itiSeq(randInd) - sign(itiGapInSeq)*obj.TR;
                        
                    itiGapInSeq = sum(itiSeq) - obj.iti.mean*nTrials; 

                    numChangesMade = numChangesMade + 1;
                    if numChangesMade > nTrials
                        % if we have to adjust ITIs over nTrial times, maybe we're going too far
                        return;
                    end     
                end

                nominalMeanMatched = true;
            end
        end

        function [eventList, eventListWIti] = assembleEventList(obj, condIDs, itiSeq)
            nTrials = length(condIDs);
            nEventsPerTrial = obj.epochsPerCond(condIDs);
            nEvents = sum(nEventsPerTrial);
        
            if isempty(condIDs)
                eventListWIti = fm_eventList.preallocate(0);
                return;
            end

            eventListWIti = fm_eventList.preallocate(nEvents+length(itiSeq), obj.runDuration);
            timePoint = 0;

            bInd = 1; eInd = nEventsPerTrial(1);
            for t = 1:nTrials
                eventListWIti.Trial(bInd:eInd) = t;
                eventListWIti.ID(bInd:eInd) = obj.eventIDs{condIDs(t)};
                eventListWIti.Activity(bInd:eInd) = 1;
                eventListWIti.Duration(bInd:eInd) = obj.durations{condIDs(t)};
                eventListWIti.Onset(bInd:eInd) = obj.onsets{condIDs(t)} + timePoint;
                timePoint = timePoint + obj.durationPerCond(condIDs(t));
                
                eventListWIti.Trial(eInd+1) = 0;
                eventListWIti.ID(eInd+1) = 0;
                eventListWIti.Activity(eInd+1) = 0;
                eventListWIti.Duration(eInd+1) = itiSeq(t);
                eventListWIti.Onset(eInd+1) = timePoint;
                timePoint = timePoint + itiSeq(t);
    
                if t == nTrials, break; end
                bInd = eInd + 2; % +2 because of added ITI
                eInd = bInd + obj.epochsPerCond(condIDs(t+1)) - 1;
            end

            eventList = eventListWIti;
            eventList.content = eventList.content(eventListWIti.Trial ~= 0, :);
            eventList.validate();
        end

        function checkProperties(obj)
            assert(~isempty(obj.TR), "TR is not set");
            assert(~isempty(obj.runDuration), "runDuration is not set");
            assert(~isempty(obj.itiModel), 'itiModel is not set');
            assert(~isempty(obj.itiParams), 'itiParams is not set');

            switch lower(obj.itiModel)
                case 'fixed'
                    assert(length(obj.itiParams) == 1,...
                        "Fixed ITI model should get only 1 parameter");
                case 'uniform'
                    assert(length(obj.itiParams) == 2,...
                        "Uniform ITI model should get 2 parameters: min and max");
                case 'exponential'
                    assert(length(obj.itiParams) == 2,...
                        "Truncated exponential ITI model should get 2 parameters: min and max");
            end

            if ~isRound(obj.itiParams./obj.TR)
                error('ITI parameters should be a multiple of the temporal resolution.');
            end
        end

        function computeTrialParameters(obj)
            obj.epochsPerCond = cellfun(@length, obj.eventIDs);
            meanTrialDuration = (obj.durationPerCond * obj.probabilities') ./ sum(obj.probabilities);
            obj.meanCondDuration = meanTrialDuration + obj.iti.mean;
        end

        function computeItiParameters(obj)
            switch lower(obj.itiModel) % for uniform find itiMean, otherwise it should be given
                case 'fixed'
                    obj.iti.mean = obj.itiParams;

                case 'uniform'
                    obj.iti.min = obj.itiParams(1);
                    obj.iti.max = obj.itiParams(2);
                    obj.iti.mean = mean(obj.itiParams);

                case 'exponential'
                    obj.iti.min = obj.itiParams(1);
                    obj.iti.max = obj.itiParams(2);
            end

            if any(strcmpi(obj.itiModel, {'uniform', 'exponential'}))
                obj.iti.minAdj = obj.iti.min - obj.TR/2;
                obj.iti.maxAdj = obj.iti.max + obj.TR/2;
                obj.iti.rangeAdj = obj.iti.maxAdj - obj.iti.minAdj;
            end

            if strcmpi(obj.itiModel, 'exponential')
                obj.iti.mean = obj.lambda - obj.iti.rangeAdj*(exp(obj.iti.rangeAdj/obj.lambda)-1)^(-1) + obj.iti.minAdj;
            end
        end
    end

    methods % set and get methods
        function set.task(obj, task)
            propertiesFound = ismember(...
                ["Probability", "Durations", "Onsets", "EventIDs"], ...
                string(task.contentNumerical.Properties.VariableNames(:)));

            if ~propertiesFound
                error('Not all necessary properies are found in the provided task table.');
            end

            obj.probabilities   = task.contentNumerical.Probability(:)';
            obj.durations       = task.contentNumerical.Durations(:)';
            obj.onsets          = task.contentNumerical.Onsets(:)';
            obj.eventIDs        = task.contentNumerical.EventIDs(:)';
            obj.durationPerCond = task.contentNumerical.TotalDuration(:)';

            obj.privateTask = task;
        end

        function task = get.task(obj)
            task = obj.privateTask;
        end

        function set.probabilities(obj, probabilities)
            assert(isRound(probabilities), "Probabilities must be whole numbers");
            obj.probabilities = probabilities ./ gcdOfMany(probabilities);
        end

        function set.TR(obj, TR)
            assert(numel(TR) == 1, ...
                   "TR has to be set as a single value");
            obj.TR = TR;
        end

        function set.runDuration(obj, runDuration)
            assert(numel(runDuration) == 1, ...
                   "runDuration has to be set a single value");
            obj.runDuration = runDuration;
        end
    end

    methods (Access = protected, Static = true)
        function out = get1ToNInTheseAmounts(amounts)
            out = nan(sum(amounts), 1);

            startIdx = 1;
            for i = 1:length(amounts)
                endIdx = startIdx + amounts(i) - 1;
                out(startIdx:endIdx) = i * ones(amounts(i), 1);
                startIdx = endIdx + 1;
            end
        end
    end
end