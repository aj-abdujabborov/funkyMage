
classdef fm_simulation < matlab.mixin.Copyable
    properties
        trialsTable;
    end
 
    methods
        function obj = fm_simulation()
            obj.makeTrialsTable();
        end

        function generate()
            % produce ground-truth neural patterns
            % make runOutlines
            % createNTS
            % convolve with HRF
            % add noise
        end

        function saveToNifti(sampleNii)
            % take sample nifti and replace it with current data
            % or you could try to generate new data from scratch.
        end

        function generateNoise()
            fm_Noise(noiseParams, noiseData);
        end

        function saveToMat(sampleNii)

        end

    end

    
    
end